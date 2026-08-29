//! `places` — the half of "what is near me and is it open right now" that Apple Maps cannot
//! answer.
//!
//! # Why this module exists at all
//!
//! The child already searches places through `imcp`'s `maps_search`, and that tool returns
//! name, street address, postcode, latitude, longitude, phone and website URL. It returns **no
//! opening hours and no ratings, ever** — a hard limit of the upstream data source, not a
//! configuration mistake. So a turn could find a café and could not say whether walking to it
//! was worth doing. This module supplies the missing half: hours, and enough structure to
//! decide *open at 07:00 on a Thursday* without re-reading prose.
//!
//! # The naming rule, which is not negotiable — and the one thing it never covered
//!
//! **Nothing in the ADVERTISED SURFACE names a provider.** Not the tool names, not the
//! descriptions, not the schemas, not an output field NAME. This module speaks
//! OpenStreetMap — Overpass for nearby search, Nominatim for the address of a specific
//! object — and [`crate::places_google`] speaks Google Places, and both answer to exactly
//! these two tool names. The whole point of the design is that when a second provider lands,
//! `DEFAULT_ALLOWED_TOOLS` and the containment record's `toolset_args` DO NOT CHANGE: adding
//! a provider must not cost a live battery re-run. That held; the second provider changed
//! neither.
//!
//! What the rule never covered, and must not, is the **value** of a field saying which source
//! answered. `place_json` emits a `provider` key whose value is `"openstreetmap"`, and the
//! Google builder emits `"google_places"`. That is data, not surface: the field NAME is
//! `provider` on both paths, so nothing about the tool contract moves when a third source
//! appears, and no argv anywhere contains either string.
//!
//! It is load-bearing rather than decorative. This source carries no ratings and thin hours
//! coverage; the other carries both. Without the field, a caller seeing no rating cannot tell
//! *"this place has no rating"* from *"this answer came from the source that has none"* — and
//! those two call for different next moves. Same for a missing `opening_hours_raw`.
//!
//! **A result is never blended.** Every field in one place record comes from the one source
//! that record names. Merging a Google rating onto an OSM record would produce an object no
//! provider ever said, whose `provider` field would then be a lie.
//!
//! # No free text ever leaves the host
//!
//! `places_search` takes a free-text query, and that string is used ENTIRELY ON THIS SIDE. It
//! is matched against [`CATEGORIES`], a closed compile-time table, to pick OSM tag filters
//! that are themselves compile-time constants; then, after the response comes back, it is used
//! again to filter results by name. It is never interpolated into an Overpass query, a URL, or
//! any other wire format.
//!
//! That is worth stating plainly because the same child reads attacker-authored content
//! (WhatsApp and iMessage bodies, mail) and the standing concern about `maps_search` is that
//! its query string is an egress channel out of exactly that child. This server does not have
//! that shape. What leaves the host is a latitude, a longitude, a radius, and — for
//! `place_details` — an object id this module has already validated against
//! `^(node|way|relation)/[0-9]+$`. There is no string a turn can author that reaches a remote
//! service, so there is nothing to sanitize and nothing to get wrong later.
//!
//! The cost of that choice is a real capability limit, recorded rather than hidden: a query
//! naming no known category falls back to a broad POI tag set, and name matching is a
//! client-side substring test over whatever that returned. See [`categories_for_query`].
//!
//! # There are no ratings in THIS source
//!
//! OSM carries none, no proxy for one exists in the data, and [`place_json`] does not emit a
//! `rating` key — not even null. A null rating is worse than a missing one: a caller that sees
//! the key learns the concept exists and may render "0" or "unrated" for a place that is
//! simply outside this provider's coverage.
//!
//! Ratings now arrive from [`crate::places_google`], which emits `rating` and `rating_count`
//! **together or not at all** — a bare rating with no count is not usable information, because
//! 5.0 from one person and 4.6 from eleven thousand are not the same claim. Which source a
//! record came from is on the record.
//!
//! # Which source answers, and what happens when it cannot
//!
//! Google Places is preferred whenever a key is configured, because its hours coverage and
//! its ratings are the entire reason it was added. OpenStreetMap serves the request instead
//! when there is no key, when the deployment pins this source with `JESSE_PLACES_PROVIDER`,
//! when the query names a category Google has no type for, when the per-window request budget
//! is spent, or when the Google call fails. **The server works with no key at all, exactly as
//! it did before**, and every response says which source served it and — when it was not the
//! preferred one — why.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{Datelike, Timelike, Utc};
use serde_json::{json, Map, Value};
use tokio::sync::Mutex;

use crate::places_google::{
    google_details_field_mask, google_distance, google_name_hit, google_place_json,
    google_search_field_mask, BudgetState, GoogleConfig, GoogleProvider, GOOGLE_ATTRIBUTION,
    GOOGLE_MAX_RESULTS,
};

// ---------------------------------------------------------------------------------------
// Which source answered
// ---------------------------------------------------------------------------------------

/// The two sources this server can answer from.
///
/// The LABELS are values, never field names and never argv — see the module docs on why that
/// distinction is the whole reason a second provider costs no containment battery.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    OpenStreetMap,
    GooglePlaces,
}

impl Provider {
    pub fn label(&self) -> &'static str {
        match self {
            Provider::OpenStreetMap => "openstreetmap",
            Provider::GooglePlaces => "google_places",
        }
    }
}

/// How much a caller asked for, and therefore how much the answer is allowed to cost.
///
/// # Why this is a parameter rather than a second pair of tools
///
/// The expensive fields — review text above all — are worth having and are not worth paying
/// for on every lookup. A tool cannot express that with a fixed field set: either the cheap
/// answer is the only answer available (which is what shipped in 0.104.0) or every answer is
/// billed at the dearest tier. So the CALLER chooses, per call, and the default is exactly
/// what shipped.
///
/// **It is a parameter and not a third and fourth tool name.** `DEFAULT_ALLOWED_TOOLS` and
/// `MAIN_CHILD_MCP_CONFIG` carry TOOL NAMES, never schemas, so an added property moves no
/// argv, so [`crate::levelgate::validate_toolset_argv`] still finds strict equality with the
/// recorded `toolset_args` and this costs no containment battery. A third tool would have
/// cost one. That is the same bet the provider-agnostic names made in 0.100.0, and it is why
/// every new capability here has to arrive as an argument.
///
/// # What each level means
///
/// [`DetailLevel::Standard`] is the 0.104.0 contract, unchanged in every byte that leaves this
/// host: the same field mask, the same SKU, the same record shape. [`DetailLevel::Rich`] adds the
/// two Enterprise + Atmosphere fields that were actually missing — review text and an
/// editorial summary — and nothing else. It is **materially dearer per call**, which is why
/// it has its own ceiling ([`crate::places_google::DEFAULT_GOOGLE_MAX_RICH_CALLS`]) rather
/// than sharing the ordinary one.
///
/// The free source has no equivalent fields at all, so a `rich` request it serves is answered
/// at `standard` with that stated in the response — the same way a fallback states itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum DetailLevel {
    /// Exactly what 0.104.0 returned, at exactly what 0.104.0 cost.
    #[default]
    Standard,
    /// Plus review text and an editorial summary, at the dearer tier.
    Rich,
}

impl DetailLevel {
    /// The value echoed to the caller. A VALUE, never a field name and never argv — the same
    /// distinction [`Provider::label`] rests on.
    pub fn label(&self) -> &'static str {
        match self {
            DetailLevel::Standard => "standard",
            DetailLevel::Rich => "rich",
        }
    }

    /// The billing tier a mask at this level sits in, in the paid provider's own vocabulary.
    /// This is what the ledger's third column carries and what the response reports, so that
    /// "what did this cost" is answerable from either without a lookup table.
    pub fn cost_tier(&self) -> &'static str {
        match self {
            DetailLevel::Standard => "enterprise",
            DetailLevel::Rich => "enterprise_atmosphere",
        }
    }

    pub fn is_rich(&self) -> bool {
        *self == DetailLevel::Rich
    }

    /// Read the `detail` argument.
    ///
    /// **An unrecognised value is an ERROR, not a silent downgrade to the default**, which is
    /// the opposite of how this module treats a mistyped environment variable — and
    /// deliberately. A bad env var must not take the capability out for the conversation. A
    /// bad tool argument is a caller that believes it asked for something it did not get, and
    /// answering it cheaply while it thinks it paid for reviews is the failure worth
    /// preventing. Same reasoning as the out-of-range `radius_m` rejection.
    pub fn parse_arg(args: &Value) -> Result<Self, String> {
        match args.get("detail") {
            None | Some(Value::Null) => Ok(DetailLevel::Standard),
            Some(Value::String(s)) => match s.trim().to_ascii_lowercase().as_str() {
                "standard" => Ok(DetailLevel::Standard),
                "rich" => Ok(DetailLevel::Rich),
                other => Err(format!(
                    "detail must be \"standard\" or \"rich\", got {other:?}"
                )),
            },
            Some(other) => Err(format!(
                "detail must be a string, \"standard\" or \"rich\", got {other}"
            )),
        }
    }
}

/// Which source a deployment wants, from `JESSE_PLACES_PROVIDER`.
///
/// **There is deliberately no "Google only".** The OpenStreetMap fallback cannot be switched
/// off, because the property that makes this server safe to depend on is that it keeps
/// answering — with no key, with a spent budget, with the paid backend down. A mode that could
/// turn a working tool into a failing one in exchange for nothing is a mode not worth having.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderPreference {
    /// Google Places when a key is configured, OpenStreetMap otherwise. The default.
    Auto,
    /// OpenStreetMap only. Google is not called even when a key is present — which is what
    /// makes a like-for-like comparison of the two sources possible from one deployment.
    OpenStreetMapOnly,
}

impl ProviderPreference {
    /// Anything unrecognised is `Auto`, on the same terms as every other value here: a
    /// mistyped environment variable must not take the capability out for the conversation.
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "openstreetmap" | "osm" => ProviderPreference::OpenStreetMapOnly,
            _ => ProviderPreference::Auto,
        }
    }
}

/// The public Overpass instance, used when `JESSE_PLACES_OVERPASS_URL` is unset.
pub const DEFAULT_OVERPASS_URL: &str = "https://overpass-api.de/api/interpreter";

/// The public Nominatim instance, used when `JESSE_PLACES_NOMINATIM_URL` is unset.
pub const DEFAULT_NOMINATIM_URL: &str = "https://nominatim.openstreetmap.org";

/// The default `User-Agent`.
///
/// **BOTH BACKING SERVICES REQUIRE A DESCRIPTIVE ONE WITH A ROUTE TO A HUMAN**, and both will
/// rate-limit or block a generic client (a bare `reqwest/0.12`, or anything that looks like a
/// scraper). This names the software and a public repository rather than a person: the
/// `ci-guards.sh` personal-infrastructure scan fails a tracked file carrying a real
/// identifier, and an operator email in a source constant is one. Override with
/// `JESSE_PLACES_USER_AGENT` on a deployment that wants a direct contact.
pub const DEFAULT_USER_AGENT: &str =
    "jesse-bridge-places/1.0 (+https://github.com/tag1consulting/jesse-app)";

/// Minimum gap between outbound requests, in milliseconds.
///
/// **Nominatim's usage policy caps a client at roughly one request per second and forbids
/// bulk querying.** That is a limit on the CLIENT, so it is enforced HERE — inside the server,
/// against a shared gate covering both backends — rather than documented as a caller
/// convention. A convention is not a rate limit: the caller is a language model that will
/// happily fan out three lookups in one turn, and the consequence of exceeding the policy is
/// the shared IP being blocked for everyone on it.
pub const DEFAULT_MIN_INTERVAL_MS: u64 = 1_000;

/// How long a fetched response stays reusable, in seconds.
///
/// Sized for the shape of the traffic rather than for freshness: a conversation asks "what's
/// near me", then "is the second one open", then "what's their number", and all three are the
/// same underlying object. Five minutes collapses that into one round trip while being far
/// shorter than the rate at which opening hours change (they are edited in OSM, by hand, on a
/// timescale of months).
pub const DEFAULT_CACHE_TTL_SECS: u64 = 300;

/// Hard cap on cache entries, so a long-lived server cannot grow without bound.
const CACHE_CAPACITY: usize = 256;

/// Ceiling on `radius_m`. Overpass bills by area and a query with a large `around` over a
/// dense city is the shape that gets an instance to hang up on you.
const MAX_RADIUS_M: u32 = 20_000;

/// Ceiling on `limit`, and the number of elements Overpass is asked for.
const MAX_LIMIT: usize = 50;

// ---------------------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------------------

/// Everything about this server that a deployment can move.
///
/// All of it is environment-read at startup and none of it is reachable from a tool argument.
/// The distinction matters: the startup gate's own error message says environment variables
/// cannot grant a tool, and nothing here tries to — these choose an endpoint and a politeness
/// budget, not a capability.
#[derive(Clone, Debug)]
pub struct PlacesConfig {
    /// Overpass endpoint. Configurable so the public instance being down or refusing service
    /// is an operator action rather than a code change; a self-hosted or mirrored instance
    /// speaks the same API.
    pub overpass_url: String,
    /// Nominatim base URL (no trailing slash). Same reasoning as `overpass_url`.
    pub nominatim_url: String,
    /// See [`DEFAULT_USER_AGENT`].
    pub user_agent: String,
    /// See [`DEFAULT_MIN_INTERVAL_MS`].
    pub min_interval: Duration,
    /// See [`DEFAULT_CACHE_TTL_SECS`].
    pub cache_ttl: Duration,
    /// Per-request wall clock ceiling. Overpass is genuinely slow under load and a 10s
    /// timeout turns a working query into a mystery failure.
    pub http_timeout: Duration,
    /// The zone `open_now` is computed against when a call does not name one, as an IANA
    /// name. Unset means the host's own zone.
    pub default_timezone: Option<String>,
    /// Which source this deployment wants. See [`ProviderPreference`].
    pub provider_preference: ProviderPreference,
    /// The paid provider's configuration, or `None` when no key is set — which is what
    /// "there is no second provider on this deployment" means, everywhere in this module.
    pub google: Option<GoogleConfig>,
}

impl Default for PlacesConfig {
    fn default() -> Self {
        Self {
            overpass_url: DEFAULT_OVERPASS_URL.to_string(),
            nominatim_url: DEFAULT_NOMINATIM_URL.to_string(),
            user_agent: DEFAULT_USER_AGENT.to_string(),
            min_interval: Duration::from_millis(DEFAULT_MIN_INTERVAL_MS),
            cache_ttl: Duration::from_secs(DEFAULT_CACHE_TTL_SECS),
            http_timeout: Duration::from_secs(45),
            default_timezone: None,
            provider_preference: ProviderPreference::Auto,
            // NOT read from the environment here. `Default` is what tests and callers get
            // when they build a config by hand, and a default that quietly picked up a real
            // API key from the ambient environment would let a unit test spend money.
            google: None,
        }
    }
}

impl PlacesConfig {
    /// Read the environment, falling back to the defaults above for anything absent or
    /// unparseable. A bad value is treated as absent rather than fatal: this server is spawned
    /// as a child of a turn, and refusing to start over a mistyped duration takes the whole
    /// capability out for the conversation.
    pub fn from_env() -> Self {
        let d = Self::default();
        Self {
            overpass_url: non_empty("JESSE_PLACES_OVERPASS_URL").unwrap_or(d.overpass_url),
            nominatim_url: non_empty("JESSE_PLACES_NOMINATIM_URL")
                .map(|s| s.trim_end_matches('/').to_string())
                .unwrap_or(d.nominatim_url),
            user_agent: non_empty("JESSE_PLACES_USER_AGENT").unwrap_or(d.user_agent),
            min_interval: non_empty("JESSE_PLACES_MIN_INTERVAL_MS")
                .and_then(|s| s.parse::<u64>().ok())
                .map(Duration::from_millis)
                .unwrap_or(d.min_interval),
            cache_ttl: non_empty("JESSE_PLACES_CACHE_TTL_SECS")
                .and_then(|s| s.parse::<u64>().ok())
                .map(Duration::from_secs)
                .unwrap_or(d.cache_ttl),
            http_timeout: non_empty("JESSE_PLACES_HTTP_TIMEOUT_SECS")
                .and_then(|s| s.parse::<u64>().ok())
                .map(Duration::from_secs)
                .unwrap_or(d.http_timeout),
            default_timezone: non_empty("JESSE_PLACES_TIMEZONE"),
            provider_preference: non_empty("JESSE_PLACES_PROVIDER")
                .map(|s| ProviderPreference::parse(&s))
                .unwrap_or(ProviderPreference::Auto),
            google: GoogleConfig::from_env(),
        }
    }
}

fn non_empty(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.trim().is_empty())
}

// ---------------------------------------------------------------------------------------
// Category mapping — the closed table that keeps free text off the wire
// ---------------------------------------------------------------------------------------

/// One OSM tag filter, as a compile-time constant.
///
/// `value` being `None` means "any value for this key" (`["shop"]`), and `regex` means the
/// value is an anchored alternation rather than a literal. Every one of these is a `const` in
/// [`CATEGORIES`] or [`FALLBACK_FILTERS`]; nothing constructs one from a caller's input, which
/// is what makes Overpass query building injection-free by construction rather than by
/// escaping.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TagFilter {
    pub key: &'static str,
    pub value: Option<&'static str>,
    pub regex: bool,
}

impl TagFilter {
    const fn eq(key: &'static str, value: &'static str) -> Self {
        Self {
            key,
            value: Some(value),
            regex: false,
        }
    }
    const fn any(key: &'static str) -> Self {
        Self {
            key,
            value: None,
            regex: false,
        }
    }
    const fn matching(key: &'static str, value: &'static str) -> Self {
        Self {
            key,
            value: Some(value),
            regex: true,
        }
    }

    /// Render as an Overpass tag predicate. Every byte comes from a `'static` constant.
    fn render(&self) -> String {
        match (self.value, self.regex) {
            (None, _) => format!("[\"{}\"]", self.key),
            (Some(v), false) => format!("[\"{}\"=\"{}\"]", self.key, v),
            (Some(v), true) => format!("[\"{}\"~\"{}\"]", self.key, v),
        }
    }
}

/// A named category: the words a person might use for it, and how each source expresses it.
///
/// **One table, both providers.** `filters` are OSM tag predicates and `google_types` are
/// Google Places "Table A" types, and they sit on the same row precisely so that the closed
/// compile-time table which keeps free text off the OSM wire keeps it off the Google wire too.
/// A second table would have been a second place for a caller's string to leak into a request.
#[derive(Clone, Copy, Debug)]
pub struct Category {
    /// The category's own name, echoed to the caller as `category`.
    pub name: &'static str,
    /// Words that select this category. Matched as whole words against the lowercased query.
    pub keywords: &'static [&'static str],
    pub filters: &'static [TagFilter],
    /// The Google Places types this category maps to, from that API's Table A.
    ///
    /// **Empty means "this source cannot express this category"**, not "match anything". Three
    /// rows are empty because Google's type table genuinely has no equivalent — there is no
    /// optician, no newsagent and no greengrocer in it — and a query that lands on one of them
    /// is served by OpenStreetMap with that stated as the reason. Substituting a broader type
    /// (`store`, `convenience_store`) would answer a different question while looking like it
    /// had answered this one.
    ///
    /// Every value here was checked against the published Table A on 2026-08-29. A test
    /// asserts the SHAPE (lowercase, `[a-z0-9_]`, no duplicates within a row) because that is
    /// all a test can assert without vendoring a 478-row table that would go stale silently.
    ///
    /// What keeps a typo from being serious is the fallback rather than the check: that API
    /// answers an unknown type with a 400 for the WHOLE request, and a failed call here falls
    /// through to OpenStreetMap with the failure stated in `provider_fallback_reason`. A
    /// mistyped type therefore degrades one category to the free source loudly; it does not
    /// take the tool out.
    pub google_types: &'static [&'static str],
}

/// The closed keyword table.
///
/// This is deliberately a hand-written list rather than anything derived: it is the ONLY thing
/// standing between a caller's free text and the query that goes out, so it has to be
/// reviewable at a glance. Adding a category is a source change, which is the point.
pub const CATEGORIES: &[Category] = &[
    Category {
        name: "cafe",
        keywords: &["cafe", "café", "coffee", "coffeeshop", "espresso"],
        filters: &[TagFilter::eq("amenity", "cafe")],
        google_types: &["cafe", "coffee_shop"],
    },
    Category {
        name: "restaurant",
        keywords: &["restaurant", "dinner", "lunch", "bistro", "trattoria"],
        filters: &[TagFilter::eq("amenity", "restaurant")],
        google_types: &["restaurant"],
    },
    Category {
        name: "fast_food",
        keywords: &[
            "takeaway", "takeout", "fastfood", "burger", "kebab", "chippy",
        ],
        filters: &[TagFilter::eq("amenity", "fast_food")],
        google_types: &["fast_food_restaurant"],
    },
    Category {
        name: "pub",
        keywords: &["pub", "tavern", "alehouse"],
        filters: &[TagFilter::eq("amenity", "pub")],
        google_types: &["pub"],
    },
    Category {
        name: "bar",
        keywords: &["bar", "cocktails", "wine bar"],
        filters: &[TagFilter::eq("amenity", "bar")],
        google_types: &["bar"],
    },
    Category {
        name: "nightclub",
        keywords: &["nightclub", "club"],
        filters: &[TagFilter::eq("amenity", "nightclub")],
        google_types: &["night_club"],
    },
    Category {
        name: "ice_cream",
        keywords: &["gelato", "icecream"],
        filters: &[TagFilter::eq("amenity", "ice_cream")],
        google_types: &["ice_cream_shop"],
    },
    Category {
        name: "bakery",
        keywords: &["bakery", "baker", "bread", "patisserie"],
        filters: &[TagFilter::eq("shop", "bakery")],
        google_types: &["bakery"],
    },
    Category {
        name: "supermarket",
        keywords: &["supermarket", "grocery", "groceries", "grocer"],
        filters: &[TagFilter::eq("shop", "supermarket")],
        google_types: &["supermarket", "grocery_store"],
    },
    Category {
        name: "convenience",
        keywords: &["convenience", "cornershop"],
        filters: &[TagFilter::eq("shop", "convenience")],
        google_types: &["convenience_store"],
    },
    Category {
        name: "deli",
        keywords: &["deli", "delicatessen"],
        filters: &[TagFilter::eq("shop", "deli")],
        google_types: &["deli"],
    },
    Category {
        name: "butcher",
        keywords: &["butcher", "butchers"],
        filters: &[TagFilter::eq("shop", "butcher")],
        google_types: &["butcher_shop"],
    },
    Category {
        name: "greengrocer",
        keywords: &["greengrocer", "fruit", "vegetables"],
        filters: &[TagFilter::eq("shop", "greengrocer")],
        google_types: &[],
    },
    Category {
        name: "alcohol",
        keywords: &["offlicence", "liquor", "wine shop", "whisky", "bottleshop"],
        filters: &[TagFilter::eq("shop", "alcohol")],
        google_types: &["liquor_store"],
    },
    Category {
        name: "pharmacy",
        keywords: &["pharmacy", "chemist", "drugstore", "apotheke", "farmacia"],
        filters: &[TagFilter::eq("amenity", "pharmacy")],
        google_types: &["pharmacy", "drugstore"],
    },
    Category {
        name: "doctors",
        keywords: &["doctor", "doctors", "gp", "surgery", "clinic"],
        filters: &[TagFilter::eq("amenity", "doctors")],
        google_types: &["doctor"],
    },
    Category {
        name: "dentist",
        keywords: &["dentist", "dental"],
        filters: &[TagFilter::eq("amenity", "dentist")],
        google_types: &["dentist"],
    },
    Category {
        name: "hospital",
        keywords: &["hospital", "a&e", "emergency room"],
        filters: &[TagFilter::eq("amenity", "hospital")],
        google_types: &["hospital"],
    },
    Category {
        name: "veterinary",
        keywords: &["vet", "vets", "veterinary"],
        filters: &[TagFilter::eq("amenity", "veterinary")],
        google_types: &["veterinary_care"],
    },
    Category {
        name: "bank",
        keywords: &["bank"],
        filters: &[TagFilter::eq("amenity", "bank")],
        google_types: &["bank"],
    },
    Category {
        name: "atm",
        keywords: &["atm", "cashpoint", "cash machine"],
        filters: &[TagFilter::eq("amenity", "atm")],
        google_types: &["atm"],
    },
    Category {
        name: "post_office",
        keywords: &["post office", "postoffice", "post"],
        filters: &[TagFilter::eq("amenity", "post_office")],
        google_types: &["post_office"],
    },
    Category {
        name: "library",
        keywords: &["library"],
        filters: &[TagFilter::eq("amenity", "library")],
        google_types: &["library"],
    },
    Category {
        name: "fuel",
        keywords: &["petrol", "fuel", "gas station", "diesel", "filling station"],
        filters: &[TagFilter::eq("amenity", "fuel")],
        google_types: &["gas_station"],
    },
    Category {
        name: "parking",
        keywords: &["parking", "car park", "carpark"],
        filters: &[TagFilter::eq("amenity", "parking")],
        google_types: &["parking"],
    },
    Category {
        name: "toilets",
        keywords: &["toilet", "toilets", "loo", "restroom", "wc"],
        filters: &[TagFilter::eq("amenity", "toilets")],
        google_types: &["public_bathroom"],
    },
    Category {
        name: "cinema",
        keywords: &["cinema", "movies", "movie theater"],
        filters: &[TagFilter::eq("amenity", "cinema")],
        google_types: &["movie_theater"],
    },
    Category {
        name: "theatre",
        keywords: &["theatre", "theater"],
        filters: &[TagFilter::eq("amenity", "theatre")],
        google_types: &["performing_arts_theater"],
    },
    Category {
        name: "place_of_worship",
        keywords: &["church", "mosque", "synagogue", "temple"],
        filters: &[TagFilter::eq("amenity", "place_of_worship")],
        google_types: &["church", "mosque", "synagogue", "hindu_temple"],
    },
    Category {
        name: "museum",
        keywords: &["museum", "gallery"],
        filters: &[TagFilter::eq("tourism", "museum")],
        google_types: &["museum", "art_gallery"],
    },
    Category {
        name: "hotel",
        keywords: &["hotel", "hostel", "b&b", "guesthouse"],
        filters: &[TagFilter::matching(
            "tourism",
            "^(hotel|hostel|guest_house|motel)$",
        )],
        google_types: &[
            "hotel",
            "motel",
            "hostel",
            "guest_house",
            "bed_and_breakfast",
        ],
    },
    Category {
        name: "attraction",
        keywords: &["attraction", "sightseeing", "viewpoint"],
        filters: &[TagFilter::matching(
            "tourism",
            "^(attraction|viewpoint|artwork)$",
        )],
        google_types: &["tourist_attraction"],
    },
    Category {
        name: "fitness_centre",
        keywords: &["gym", "fitness", "climbing"],
        filters: &[TagFilter::matching(
            "leisure",
            "^(fitness_centre|sports_centre|climbing)$",
        )],
        google_types: &["gym", "fitness_center", "sports_complex"],
    },
    Category {
        name: "swimming_pool",
        keywords: &["pool", "swimming", "swim"],
        filters: &[TagFilter::matching(
            "leisure",
            "^(swimming_pool|water_park)$",
        )],
        google_types: &["swimming_pool", "water_park"],
    },
    Category {
        name: "park",
        keywords: &["park", "garden", "green space"],
        filters: &[TagFilter::matching("leisure", "^(park|garden)$")],
        google_types: &["park", "garden"],
    },
    Category {
        name: "playground",
        keywords: &["playground", "play park"],
        filters: &[TagFilter::eq("leisure", "playground")],
        google_types: &["playground"],
    },
    Category {
        name: "hairdresser",
        keywords: &["hairdresser", "barber", "haircut", "salon"],
        filters: &[TagFilter::eq("shop", "hairdresser")],
        google_types: &["hair_salon", "barber_shop"],
    },
    Category {
        name: "laundry",
        keywords: &["laundry", "launderette", "laundrette", "dry cleaner"],
        filters: &[TagFilter::matching("shop", "^(laundry|dry_cleaning)$")],
        google_types: &["laundry"],
    },
    Category {
        name: "doityourself",
        keywords: &["hardware", "diy", "tools"],
        filters: &[TagFilter::matching(
            "shop",
            "^(doityourself|hardware|trade)$",
        )],
        google_types: &["hardware_store", "home_improvement_store"],
    },
    Category {
        name: "books",
        keywords: &["bookshop", "bookstore", "books", "bookseller"],
        filters: &[TagFilter::eq("shop", "books")],
        google_types: &["book_store"],
    },
    Category {
        name: "clothes",
        keywords: &["clothes", "clothing", "fashion", "shoes"],
        filters: &[TagFilter::matching("shop", "^(clothes|shoes|boutique)$")],
        google_types: &["clothing_store", "shoe_store"],
    },
    Category {
        name: "electronics",
        keywords: &["electronics", "computer", "phone shop"],
        filters: &[TagFilter::matching(
            "shop",
            "^(electronics|computer|mobile_phone)$",
        )],
        google_types: &["electronics_store", "cell_phone_store"],
    },
    Category {
        name: "optician",
        keywords: &["optician", "optometrist", "glasses"],
        filters: &[TagFilter::eq("shop", "optician")],
        google_types: &[],
    },
    Category {
        name: "florist",
        keywords: &["florist", "flowers"],
        filters: &[TagFilter::eq("shop", "florist")],
        google_types: &["florist"],
    },
    Category {
        name: "newsagent",
        keywords: &["newsagent", "newspaper"],
        filters: &[TagFilter::eq("shop", "newsagent")],
        google_types: &[],
    },
    Category {
        name: "school",
        keywords: &["school"],
        filters: &[TagFilter::eq("amenity", "school")],
        google_types: &["school", "primary_school", "secondary_school"],
    },
    Category {
        name: "university",
        keywords: &["university", "campus", "college"],
        filters: &[TagFilter::matching("amenity", "^(university|college)$")],
        google_types: &["university"],
    },
];

/// What a query matching no known category falls back to.
///
/// **This is a real capability limit and it is stated rather than papered over.** A broad POI
/// sweep plus a client-side name filter is not a geocoder: it will find "Söderberg" if
/// Söderberg is tagged as a `shop` or `amenity` within the radius, and it will miss a place
/// whose only tag is one not listed here. The alternative — putting the caller's string into a
/// Nominatim free-text search — is precisely the egress this module is shaped to avoid, so the
/// limit is accepted. A caller that knows the category should say the category.
pub const FALLBACK_FILTERS: &[TagFilter] = &[
    TagFilter::any("shop"),
    TagFilter::matching(
        "amenity",
        "^(cafe|restaurant|fast_food|pub|bar|nightclub|ice_cream|pharmacy|bank|post_office|library|cinema|theatre|fuel|marketplace)$",
    ),
    TagFilter::any("tourism"),
    TagFilter::matching(
        "leisure",
        "^(fitness_centre|sports_centre|swimming_pool|park|garden)$",
    ),
];

/// Which categories a free-text query selects.
///
/// Matching is whole-word and case-insensitive against the lowercased query, plus a
/// multi-word keyword matched as a substring (so "gas station" works). An empty result means
/// the caller gets [`FALLBACK_FILTERS`].
pub fn categories_for_query(query: &str) -> Vec<&'static Category> {
    let q = query.to_lowercase();
    let words: Vec<&str> = q
        .split(|c: char| !c.is_alphanumeric() && c != '&')
        .filter(|w| !w.is_empty())
        .collect();
    let mut out: Vec<&'static Category> = Vec::new();
    for cat in CATEGORIES {
        let hit = cat.keywords.iter().any(|kw| {
            if kw.contains(' ') {
                q.contains(kw)
            } else {
                words.iter().any(|w| w == kw)
            }
        });
        if hit && !out.iter().any(|c| c.name == cat.name) {
            out.push(cat);
        }
    }
    out
}

/// The tag filters a query resolves to, and whether they came from the table or the fallback.
fn filters_for_query(query: &str) -> (Vec<TagFilter>, Vec<&'static str>, bool) {
    let cats = categories_for_query(query);
    if cats.is_empty() {
        (FALLBACK_FILTERS.to_vec(), Vec::new(), true)
    } else {
        let mut filters = Vec::new();
        let mut names = Vec::new();
        for c in &cats {
            names.push(c.name);
            for f in c.filters {
                if !filters.contains(f) {
                    filters.push(*f);
                }
            }
        }
        (filters, names, false)
    }
}

/// The words of the query that are NOT category keywords — what a name filter should use.
///
/// "open cafe near Fountainbridge" should not filter names by "cafe": the category already
/// did that, and no café is called "cafe". Stop words are dropped for the same reason.
/// What the preferred provider can be asked for, for one query.
///
/// Three outcomes rather than "a list of types", because the empty list is ambiguous on that
/// API and the ambiguity would cost money in the wrong direction: sending no `includedTypes`
/// means "every type", which is the right answer for a query naming no category and the WRONG
/// answer for a category the provider cannot express.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GoogleTypes {
    /// The query named no known category. Ask for everything nearby and filter by name on
    /// this side — the counterpart of [`FALLBACK_FILTERS`].
    Everything,
    /// The query named categories this provider expresses.
    These(Vec<&'static str>),
    /// The query named categories and this provider expresses NONE of them. Not a failure —
    /// the other source answers, and the response says why.
    Unsupported,
}

/// Which provider types a free-text query selects, from the same closed table
/// [`filters_for_query`] reads.
pub fn google_types_for_query(query: &str) -> GoogleTypes {
    let matched = categories_for_query(query);
    if matched.is_empty() {
        return GoogleTypes::Everything;
    }
    let mut types: Vec<&'static str> = Vec::new();
    for c in matched {
        for t in c.google_types {
            if !types.contains(t) {
                types.push(t);
            }
        }
    }
    if types.is_empty() {
        GoogleTypes::Unsupported
    } else {
        GoogleTypes::These(types)
    }
}

fn name_terms(query: &str) -> Vec<String> {
    const STOP: &[&str] = &[
        "a", "an", "the", "near", "nearby", "around", "close", "by", "in", "at", "to", "me",
        "open", "now", "any", "some", "good", "best", "find", "is", "are", "there", "here",
        "place", "places", "shop", "shops", "store", "stores", "what", "s", "and", "or", "of",
        "for", "with", "my",
    ];
    let matched: Vec<&str> = categories_for_query(query)
        .iter()
        .flat_map(|c| c.keywords.iter().copied())
        .collect();
    query
        .to_lowercase()
        .split(|c: char| !c.is_alphanumeric() && c != '\'' && c != '\u{2019}')
        .filter(|w| w.len() > 1)
        .filter(|w| !STOP.contains(w))
        .filter(|w| !matched.iter().any(|k| k == w))
        .map(fold_name)
        .filter(|w| !w.is_empty())
        .collect()
}

/// Lowercase and DROP APOSTROPHES, for name comparison on both sides.
///
/// Measured rather than anticipated: a live search for `Loudons` returned nothing while
/// `Loudon's Cafe & Bakery` sat eleven metres from the search centre. Two apostrophes are in
/// play — the ASCII `'` a person types and the typographic `’` the data frequently carries
/// (`L’artigiano` is real, on the same street) — so folding one and not the other fixes half
/// the cases and looks like it works.
///
/// This is a comparison key only. The name returned to the caller is always the source
/// spelling, apostrophe and all.
pub(crate) fn fold_name(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .filter(|c| *c != '\'' && *c != '\u{2019}')
        .collect()
}

// ---------------------------------------------------------------------------------------
// Opening hours
// ---------------------------------------------------------------------------------------

/// Weekday names, Monday first, matching `chrono::Weekday::num_days_from_monday()`.
pub const WEEKDAY_NAMES: [&str; 7] = [
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
];

/// The two-letter OSM day tokens, in the same order as [`WEEKDAY_NAMES`].
const OSM_DAYS: [&str; 7] = ["mo", "tu", "we", "th", "fr", "sa", "su"];

/// One opening interval on one weekday, in minutes from that day's midnight.
///
/// `end` may be less than or equal to `start`, which means the interval RUNS PAST MIDNIGHT
/// into the following day — a bar open `Fr 20:00-02:00` is open at 00:30 on Saturday. That
/// case is the reason this is a struct with an explicit flag rather than a pair of strings:
/// a caller doing its own comparison on "20:00" and "02:00" gets Friday night wrong, every
/// time, silently.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Interval {
    pub start: u16,
    pub end: u16,
}

impl Interval {
    pub fn crosses_midnight(&self) -> bool {
        self.end <= self.start
    }

    fn as_json(&self) -> Value {
        json!({
            "start": fmt_hhmm(self.start),
            "end": fmt_hhmm(self.end),
            "crosses_midnight": self.crosses_midnight(),
        })
    }
}

fn fmt_hhmm(m: u16) -> String {
    format!("{:02}:{:02}", m / 60, m % 60)
}

/// A successfully parsed `opening_hours` value.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OpeningHours {
    /// Per weekday, Monday first. An empty list means CLOSED all day — which is information,
    /// not an absence, and is why this is not an `Option`.
    pub days: [Vec<Interval>; 7],
    /// The value was `24/7`.
    pub always_open: bool,
    /// The value carried a public-holiday rule (`PH off`, `PH 10:00-16:00`).
    ///
    /// **The rule is recognised and then NOT APPLIED**, because this module has no holiday
    /// calendar for any country and inventing one would be exactly the guess this design
    /// refuses. The flag is surfaced so a caller can see that `open_now` is a weekday answer
    /// which may be wrong on a public holiday. Dropping the flag and answering anyway would be
    /// the failure mode; failing the whole parse over it would throw away six correct days.
    pub public_holidays_unevaluated: bool,
}

impl OpeningHours {
    /// Is the venue open on `weekday` (0 = Monday) at `minute` of that day?
    ///
    /// Checks the PREVIOUS day's intervals too, for the ones that cross midnight.
    pub fn open_at(&self, weekday: usize, minute: u16) -> bool {
        if self.always_open {
            return true;
        }
        let today = &self.days[weekday % 7];
        for iv in today {
            if iv.crosses_midnight() {
                if minute >= iv.start {
                    return true;
                }
            } else if minute >= iv.start && minute < iv.end {
                return true;
            }
        }
        let yesterday = &self.days[(weekday + 6) % 7];
        for iv in yesterday {
            if iv.crosses_midnight() && minute < iv.end {
                return true;
            }
        }
        false
    }
}

/// Parse an OSM `opening_hours` value.
///
/// # What this handles, and why the rest is an error rather than a guess
///
/// `opening_hours` is its own small grammar with a very long tail — month ranges, week
/// numbers, `sunrise`/`sunset` offsets, nth-weekday-of-month selectors, comments in quotes,
/// variable dates. A regex that "mostly works" over that tail does not fail loudly; it returns
/// a confident wrong answer, and the caller has no way to tell that from a right one. So this
/// parses the forms that actually appear on shops and cafés:
///
///   * `24/7`
///   * `Mo-Fr 08:00-18:00`
///   * `Mo,We,Fr 09:00-17:00` and `Mo-Fr,Su 09:00-17:00`
///   * `Mo-Fr 08:00-12:00,13:00-18:00` (a lunchtime break)
///   * `Fr 20:00-02:00` (past midnight)
///   * `08:00-18:00` with no day selector, meaning every day
///   * `Su off` / `Su closed`
///   * `PH off` (recognised, flagged, not applied — see
///     [`OpeningHours::public_holidays_unevaluated`])
///
/// and returns `Err(reason)` for everything else, naming the rule it could not read. The
/// caller is expected to fall back to the raw string, which is why the raw string is always
/// returned alongside.
pub fn parse_opening_hours(raw: &str) -> Result<OpeningHours, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("empty opening_hours value".to_string());
    }
    let mut out = OpeningHours::default();
    let mut saw_a_rule = false;

    for rule in trimmed.split(';') {
        let rule = rule.trim();
        if rule.is_empty() {
            continue;
        }
        if rule.eq_ignore_ascii_case("24/7") {
            out.always_open = true;
            for d in 0..7 {
                out.days[d] = vec![Interval {
                    start: 0,
                    end: 1440,
                }];
            }
            saw_a_rule = true;
            continue;
        }

        let words: Vec<&str> = rule.split_whitespace().collect();
        // Split the rule into a leading day selector and a trailing time selector. A word
        // belongs to the day selector only if EVERY token in it is a known day or day range,
        // which is what keeps `Jan-Mar` or `week 1-10` from being mistaken for one.
        let mut split_at = 0usize;
        while split_at < words.len() && is_day_selector_word(words[split_at]) {
            split_at += 1;
        }
        let (day_words, time_words) = words.split_at(split_at);

        let (mut days, ph) = if day_words.is_empty() {
            ((0..7).collect::<Vec<usize>>(), false)
        } else {
            parse_day_selector(&day_words.join(""))
                .ok_or_else(|| format!("unreadable day selector in rule {rule:?}"))?
        };
        if ph {
            out.public_holidays_unevaluated = true;
        }
        if days.is_empty() && !ph {
            return Err(format!("rule {rule:?} selects no day"));
        }
        days.sort_unstable();
        days.dedup();

        if time_words.is_empty() {
            return Err(format!(
                "rule {rule:?} names days but no times; refusing to assume what that means"
            ));
        }
        // `08:00-12:00, 13:00-18:00` is legal and tokenises as two words. Nothing else in the
        // supported grammar splits on whitespace, so anything that survives this join and
        // fails to parse below is genuinely out of scope (`open "by appointment"`,
        // `sunrise-sunset`, `Su[1] 10:00-14:00`).
        let time_part = time_words.concat();

        if time_part.eq_ignore_ascii_case("off") || time_part.eq_ignore_ascii_case("closed") {
            for d in &days {
                out.days[*d].clear();
            }
            saw_a_rule = true;
            continue;
        }

        let mut intervals = Vec::new();
        for span in time_part.split(',') {
            let span = span.trim();
            if span.is_empty() {
                continue;
            }
            intervals.push(
                parse_span(span).ok_or_else(|| {
                    format!("unsupported time selector {span:?} in rule {rule:?}")
                })?,
            );
        }
        if intervals.is_empty() {
            return Err(format!("rule {rule:?} has no readable time span"));
        }
        for d in &days {
            for iv in &intervals {
                if !out.days[*d].contains(iv) {
                    out.days[*d].push(*iv);
                }
            }
        }
        saw_a_rule = true;
    }

    if !saw_a_rule {
        return Err(format!("no readable rule in {trimmed:?}"));
    }
    for d in out.days.iter_mut() {
        d.sort_by_key(|iv| iv.start);
    }
    Ok(out)
}

/// Is this whitespace-delimited word made only of day tokens, ranges and commas?
fn is_day_selector_word(w: &str) -> bool {
    let w = w.trim();
    if w.is_empty() {
        return false;
    }
    if !w
        .chars()
        .all(|c| c.is_ascii_alphabetic() || c == ',' || c == '-')
    {
        return false;
    }
    w.split(',')
        .filter(|p| !p.is_empty())
        .all(|part| part.split('-').filter(|p| !p.is_empty()).all(is_day_token))
        && w.split([',', '-']).any(|p| !p.is_empty())
}

fn is_day_token(t: &str) -> bool {
    let t = t.to_ascii_lowercase();
    OSM_DAYS.contains(&t.as_str()) || t == "ph"
}

/// Expand `Mo-Fr,Su` into day indices. Returns the indices plus whether `PH` appeared.
fn parse_day_selector(sel: &str) -> Option<(Vec<usize>, bool)> {
    let mut days = Vec::new();
    let mut ph = false;
    for part in sel.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if part.eq_ignore_ascii_case("ph") {
            ph = true;
            continue;
        }
        let ends: Vec<&str> = part.split('-').collect();
        match ends.as_slice() {
            [one] => days.push(day_index(one)?),
            [from, to] => {
                let (a, b) = (day_index(from)?, day_index(to)?);
                // `Sa-Su` is contiguous; `Fr-Mo` wraps the week end, which OSM allows.
                let mut i = a;
                loop {
                    days.push(i);
                    if i == b {
                        break;
                    }
                    i = (i + 1) % 7;
                }
            }
            _ => return None,
        }
    }
    Some((days, ph))
}

fn day_index(t: &str) -> Option<usize> {
    let t = t.trim().to_ascii_lowercase();
    OSM_DAYS.iter().position(|d| *d == t)
}

/// Parse `HH:MM-HH:MM`.
fn parse_span(s: &str) -> Option<Interval> {
    let (a, b) = s.split_once('-')?;
    let start = parse_clock(a)?;
    let end = parse_clock(b)?;
    if start == end {
        // `12:00-12:00` is either a typo or a dialect this module does not read. Either way
        // guessing "closed" or "always open" from it would be inventing an answer.
        return None;
    }
    Some(Interval { start, end })
}

fn parse_clock(s: &str) -> Option<u16> {
    let s = s.trim();
    let (h, m) = s.split_once(':')?;
    let h: u16 = h.trim().parse().ok()?;
    let m: u16 = m.trim().parse().ok()?;
    if h > 24 || m > 59 || (h == 24 && m != 0) {
        return None;
    }
    Some(h * 60 + m)
}

/// The resolved evaluation zone, and where it came from.
///
/// `pub(crate)` because [`crate::places_google`] renders hours through the same function this
/// module does — see [`hours_json_from`] — and cannot do that without naming the zone type.
pub(crate) struct Zone {
    pub(crate) tz: chrono_tz::Tz,
    pub(crate) name: String,
    pub(crate) source: &'static str,
}

fn resolve_zone(requested: Option<&str>, cfg: &PlacesConfig) -> Zone {
    if let Some(r) = requested.map(str::trim).filter(|r| !r.is_empty()) {
        if let Ok(tz) = r.parse::<chrono_tz::Tz>() {
            return Zone {
                tz,
                name: tz.name().to_string(),
                source: "request",
            };
        }
    }
    if let Some(c) = cfg.default_timezone.as_deref() {
        if let Ok(tz) = c.parse::<chrono_tz::Tz>() {
            return Zone {
                tz,
                name: tz.name().to_string(),
                source: "config",
            };
        }
    }
    if let Ok(host) = iana_time_zone::get_timezone() {
        if let Ok(tz) = host.parse::<chrono_tz::Tz>() {
            return Zone {
                tz,
                name: tz.name().to_string(),
                source: "host",
            };
        }
    }
    Zone {
        tz: chrono_tz::UTC,
        name: "UTC".to_string(),
        source: "fallback",
    }
}

/// Render the two-field hours answer.
///
/// # Two fields, never one
///
/// `opening_hours_raw` is the provider's string EXACTLY as received, and `opening_hours` is
/// the parsed structure. Neither substitutes for the other. A single prettified string cannot
/// answer "is it open at 07:00 on Thursday" without the caller re-parsing prose — which is the
/// job this function exists to do once, properly — and a parsed structure alone leaves nothing
/// to fall back to when [`parse_opening_hours`] refuses a value it cannot read.
///
/// On failure `open_now` is `null` and `parsed` is `false` with a `reason`. It is not `false`.
/// A `false` there would be indistinguishable from "closed right now", and reporting a venue
/// as shut because a string was unreadable is the specific wrong answer this whole design is
/// built to avoid.
fn hours_json(raw: &str, zone: &Zone) -> Value {
    hours_json_from(parse_opening_hours(raw), zone)
}

/// Render an ALREADY-PARSED hours result — **the one renderer both providers go through.**
///
/// This split is not tidiness. The two sources describe hours in two completely different
/// ways: OSM sends a string in its own grammar, Google sends a list of open/close instants.
/// If each had rendered its own answer, the two would have drifted into two output shapes on
/// the first change to either — and a caller would then have had to branch on `provider` to
/// read hours, which is exactly the coupling the provider-agnostic tool names exist to
/// prevent. Each source's job ends at producing an [`OpeningHours`] (or a reason it could
/// not); from here the shape is decided in one place, for both, by construction.
///
/// `open_now` is recomputed HERE for both sources rather than taken from a provider that
/// offers one. Google returns its own `openNow`, evaluated in the place's local zone; using it
/// would mean `open_now` answered a different question depending on who replied, and the
/// timezone this response names would not be the timezone the boolean was computed in.
pub(crate) fn hours_json_from(parsed: Result<OpeningHours, String>, zone: &Zone) -> Value {
    let now = Utc::now().with_timezone(&zone.tz);
    let weekday = now.weekday().num_days_from_monday() as usize;
    let minute = (now.hour() * 60 + now.minute()) as u16;

    match parsed {
        Ok(h) => {
            let mut days = Map::new();
            for (i, name) in WEEKDAY_NAMES.iter().enumerate() {
                days.insert(
                    (*name).to_string(),
                    Value::Array(h.days[i].iter().map(Interval::as_json).collect()),
                );
            }
            json!({
                "parsed": true,
                "open_now": h.open_at(weekday, minute),
                "always_open": h.always_open,
                "public_holidays_unevaluated": h.public_holidays_unevaluated,
                "timezone": zone.name,
                "timezone_source": zone.source,
                "evaluated_at": now.to_rfc3339(),
                "weekdays": Value::Object(days),
            })
        }
        Err(reason) => json!({
            "parsed": false,
            "open_now": Value::Null,
            "reason": reason,
            "timezone": zone.name,
            "timezone_source": zone.source,
            "evaluated_at": now.to_rfc3339(),
        }),
    }
}

// ---------------------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------------------

/// A cached HTTP response.
struct CacheEntry {
    body: String,
    at: Instant,
}

/// The places backend: rate-limited, cached, and the only thing in this module that touches
/// the network.
pub struct PlacesClient {
    cfg: PlacesConfig,
    http: reqwest::Client,
    /// Serialises ALL outbound OpenStreetMap requests and holds the time of the last one. One
    /// gate covers both of that source's endpoints deliberately — the policy is about the
    /// client, and two independent limiters would let a search and a lookup fire in the same
    /// tick.
    ///
    /// **The paid provider does not go through it.** This gate implements Nominatim's
    /// one-request-per-second client policy, which says nothing about any other service, and
    /// making a Google call wait a second before a fallback could then wait another is a cost
    /// with no corresponding rule behind it. What bounds the paid path is the request budget.
    gate: Mutex<Option<Instant>>,
    /// The five-minute response cache — **OpenStreetMap only.** Google's terms permit caching
    /// place ids and coordinates and nothing else (see [`crate::places_google`]), so no Google
    /// response ever reaches this map.
    cache: Mutex<HashMap<String, CacheEntry>>,
    /// The preferred source, present exactly when a key is configured.
    google: Option<GoogleProvider>,
}

impl PlacesClient {
    pub fn new(cfg: PlacesConfig) -> Result<Arc<Self>, String> {
        let http = reqwest::Client::builder()
            .user_agent(cfg.user_agent.clone())
            .timeout(cfg.http_timeout)
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        let google = cfg.google.clone().map(GoogleProvider::new);
        Ok(Arc::new(Self {
            cfg,
            http,
            gate: Mutex::new(None),
            cache: Mutex::new(HashMap::new()),
            google,
        }))
    }

    /// The preferred source, or the sentence saying why this request will not use it.
    ///
    /// Both halves are returned together so that no call site can take the provider without
    /// also having somewhere to put the reason. Every response served by the fallback carries
    /// one of these strings, including the ordinary "no key configured" case: a caller that
    /// sees no ratings is owed the difference between "there are none for this place" and
    /// "this deployment has no key for the source that has them".
    ///
    /// The `Err` is a CAUSE and not a whole sentence — no trailing "so the free source
    /// answered". `places_search` composes that on ([`FELL_BACK`]) and `place_details`
    /// composes something different, because there the free source did NOT answer.
    fn preferred(&self) -> Result<&GoogleProvider, String> {
        if self.cfg.provider_preference == ProviderPreference::OpenStreetMapOnly {
            return Err(
                "this deployment is pinned to the free source by JESSE_PLACES_PROVIDER".to_string(),
            );
        }
        self.google.as_ref().ok_or_else(|| {
            "no API key is configured for the source that carries ratings and fuller \
             opening-hours coverage"
                .to_string()
        })
    }

    /// One outbound request: cache lookup, then rate gate, then fetch, then cache store.
    ///
    /// The gate is held across the request rather than only across the sleep. That serialises
    /// requests, which is stricter than the policy requires and is the right trade here: the
    /// alternative lets N concurrent calls each observe the same "last request" instant and
    /// fire together, which is exactly the burst the policy forbids.
    async fn fetch(&self, url: &str, body: Option<String>) -> Result<String, String> {
        let key = match &body {
            Some(b) => format!("{url}\n{b}"),
            None => url.to_string(),
        };
        {
            let cache = self.cache.lock().await;
            if let Some(e) = cache.get(&key) {
                if e.at.elapsed() < self.cfg.cache_ttl {
                    return Ok(e.body.clone());
                }
            }
        }

        // ONE RETRY, and only for the statuses that mean "ask again later".
        //
        // This is not defensive padding: the public Overpass instance returns 504 for a
        // materially large fraction of by-id queries under load, and the ONLY difference
        // between a failed call and a good one is having asked twice. The retry is bounded at
        // one, goes through the same gate (so it inherits the rate limit rather than
        // sidestepping it), and covers no other status — a 400 is a bad query and asking again
        // is just rudeness toward a free service.
        let mut attempt = 0u8;
        let text = loop {
            let outcome = {
                let mut gate = self.gate.lock().await;
                if let Some(last) = *gate {
                    let since = last.elapsed();
                    if since < self.cfg.min_interval {
                        tokio::time::sleep(self.cfg.min_interval - since).await;
                    }
                }
                let req = match &body {
                    Some(b) => self.http.post(url).body(b.clone()).header(
                        reqwest::header::CONTENT_TYPE,
                        "application/x-www-form-urlencoded",
                    ),
                    None => self.http.get(url),
                };
                let resp = req.send().await;
                *gate = Some(Instant::now());
                let resp =
                    resp.map_err(|e| format!("request to the places backend failed: {e}"))?;
                let status = resp.status();
                let text = resp
                    .text()
                    .await
                    .map_err(|e| format!("reading the places backend response failed: {e}"))?;
                (status, text)
            };
            let (status, text) = outcome;
            if status.is_success() {
                break text;
            }
            let retryable = status.as_u16() == 429 || status.is_server_error();
            if retryable && attempt == 0 {
                attempt += 1;
                continue;
            }
            return Err(describe_http_failure(status.as_u16(), &text));
        };

        let mut cache = self.cache.lock().await;
        if cache.len() >= CACHE_CAPACITY {
            cache.clear();
        }
        cache.insert(
            key,
            CacheEntry {
                body: text.clone(),
                at: Instant::now(),
            },
        );
        Ok(text)
    }
    /// `places_search`, on whichever source this deployment can use for it.
    ///
    /// The arguments are validated ONCE, up front, for both sources: a radius that is out of
    /// range is out of range whoever would have answered, and validating per branch is how the
    /// two paths start disagreeing about what a legal request is.
    ///
    /// The order is: preferred source, then the free one. Every way the preferred source can
    /// fail to answer — no key, pinned off, a category it has no type for, a spent budget, a
    /// failed call — produces a SENTENCE, not a silent switch, and that sentence is in the
    /// response.
    pub async fn search(&self, args: &Value) -> Result<Value, String> {
        let query = args
            .get("query")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        let lat = num(args, "latitude").ok_or("latitude is required and must be a number")?;
        let lon = num(args, "longitude").ok_or("longitude is required and must be a number")?;
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
            return Err("latitude must be within ±90 and longitude within ±180".to_string());
        }
        let radius = num(args, "radius_m").unwrap_or(1000.0);
        if !(1.0..=f64::from(MAX_RADIUS_M)).contains(&radius) {
            return Err(format!("radius_m must be between 1 and {MAX_RADIUS_M}"));
        }
        let radius = radius.round() as u32;
        let limit = num(args, "limit").unwrap_or(15.0).round().clamp(1.0, 50.0) as usize;
        let zone = resolve_zone(args.get("timezone").and_then(Value::as_str), &self.cfg);
        // Validated up front with the rest, for the reason stated above: what a legal request
        // is must not depend on which source would have answered it.
        let detail = DetailLevel::parse_arg(args)?;
        let mut detail_report = DetailReport::new(detail);

        let (filters, categories, category_fallback) = filters_for_query(&query);
        let terms = name_terms(&query);

        let mut budget: Option<BudgetState> = None;
        let mut fallback_reason: Option<String> = None;
        let mut answer: Option<(Provider, SearchHits)> = None;

        match self.preferred() {
            Err(reason) => fallback_reason = Some(reason),
            Ok(g) => match google_types_for_query(&query) {
                // A category the preferred source has no type for is NOT an error and NOT a
                // reason to send it a broader question it can bill for. The free source has
                // the tag, so the free source answers and the response says so.
                GoogleTypes::Unsupported => {
                    fallback_reason = Some(format!(
                        "the source that carries ratings has no place type for {}",
                        categories.join(" / ")
                    ))
                }
                types => {
                    let list: &[&'static str] = match &types {
                        GoogleTypes::These(v) => v,
                        _ => &[],
                    };
                    match g
                        .search_nearby(&self.http, list, lat, lon, radius, limit, detail)
                        .await
                    {
                        Ok((body, b)) => {
                            budget = Some(b);
                            detail_report.mask = Some(google_search_field_mask(detail));
                            answer = Some((
                                Provider::GooglePlaces,
                                google_hits(
                                    &body,
                                    lat,
                                    lon,
                                    limit,
                                    &terms,
                                    matches!(types, GoogleTypes::Everything),
                                    &zone,
                                ),
                            ));
                        }
                        Err(e) => fallback_reason = Some(e),
                    }
                }
            },
        }

        if answer.is_none() {
            detail_report.served_by_free_source();
            if budget.is_none() {
                if let Some(g) = self.google.as_ref() {
                    budget = g.ledger.peek().await;
                }
            }
            answer = Some((
                Provider::OpenStreetMap,
                self.osm_hits(
                    lat,
                    lon,
                    radius,
                    limit,
                    &filters,
                    &terms,
                    category_fallback,
                    &zone,
                )
                .await?,
            ));
        }
        let (provider, hits) = answer.expect("one of the two branches sets an answer");

        // COVERAGE IS REPORTED, NOT IMPLIED, and now for ratings as well as hours. A caller
        // that cannot see how many results carried a field has no way to tell "nothing is
        // open" from "nobody has recorded this street" — and, since the second source landed,
        // no way to tell an unrated place from a source with no ratings in it.
        let with_hours = hits
            .places
            .iter()
            .filter(|p| p.get("opening_hours_raw").is_some())
            .count();
        let with_rating = hits
            .places
            .iter()
            .filter(|p| p.get("rating").is_some())
            .count();

        let mut out = json!({
            "query": query,
            "center": {"latitude": lat, "longitude": lon},
            "radius_m": radius,
            "provider": provider.label(),
            "matched_categories": categories,
            "used_fallback_categories": category_fallback,
            "name_filter_terms": terms,
            "name_filter_relaxed": hits.relaxed,
            "timezone": zone.name,
            "timezone_source": zone.source,
            "total_matches": hits.total,
            "returned": hits.places.len(),
            "with_opening_hours": with_hours,
            "without_opening_hours": hits.places.len().saturating_sub(with_hours),
            "with_rating": with_rating,
            "without_rating": hits.places.len().saturating_sub(with_rating),
            "places": hits.places,
        });
        // NO SILENT CAP. The preferred source will not return more than
        // [`GOOGLE_MAX_RESULTS`] per call whatever `limit` says, and a caller that asked for
        // 50 and got 20 is owed the difference between "that is all there is" and "that is
        // all this source will send".
        if provider == Provider::GooglePlaces && limit > GOOGLE_MAX_RESULTS {
            out["limit_capped_by_provider"] = json!(GOOGLE_MAX_RESULTS);
        }
        // THE EMPTY ANSWER EXPLAINS ITSELF, at no cost and from facts already in hand. A
        // caller that gets nothing back for a bare business name is otherwise left choosing
        // between "the place is not there" and "the tool is broken", and neither is true.
        if category_fallback && hits.places.is_empty() {
            out["no_results_explanation"] = json!(EMPTY_FALLBACK_EXPLANATION);
        }
        self.annotate(
            &mut out,
            provider,
            fallback_reason.map(|cause| format!("{cause}{FELL_BACK}")),
            budget,
            &detail_report,
        );
        Ok(out)
    }

    /// The fields every response carries about WHERE it came from and WHAT IT COST.
    ///
    /// One function so the two tools cannot disagree about them, and so a third tool could not
    /// be added without them.
    fn annotate(
        &self,
        out: &mut Value,
        provider: Provider,
        fallback_reason: Option<String>,
        budget: Option<BudgetState>,
        detail: &DetailReport,
    ) {
        let obj = out.as_object_mut().expect("responses are objects");
        if let Some(reason) = fallback_reason {
            obj.insert("provider_fallback_reason".to_string(), json!(reason));
        }
        if let Some(b) = budget {
            obj.insert("budget".to_string(), b.as_json());
            // THE SECOND CEILING IS REPORTED WHENEVER THE FIRST IS, not only on the calls it
            // governs. `budget` keeps exactly the three keys it has always carried and
            // exactly the values it always carried; the rich counters are a sibling rather
            // than two more keys inside it, so nothing reading the old object sees a change.
            obj.insert("rich_budget".to_string(), b.rich_as_json());
        }
        detail.write_into(obj);
        if provider == Provider::GooglePlaces {
            obj.insert("attribution".to_string(), json!(GOOGLE_ATTRIBUTION));
        }
    }

    /// The OpenStreetMap half of `places_search`: build the query, fetch, filter, rank.
    #[allow(clippy::too_many_arguments)]
    async fn osm_hits(
        &self,
        lat: f64,
        lon: f64,
        radius: u32,
        limit: usize,
        filters: &[TagFilter],
        terms: &[String],
        category_fallback: bool,
        zone: &Zone,
    ) -> Result<SearchHits, String> {
        let mut clauses = String::new();
        for f in filters {
            clauses.push_str(&format!(
                "  nwr{}(around:{radius},{lat},{lon});\n",
                f.render()
            ));
        }
        // EVERY BYTE OF THIS QUERY IS EITHER A COMPILE-TIME CONSTANT OR A VALIDATED NUMBER.
        // The clauses come from [`TagFilter::render`] over the closed table; `radius` is a
        // `u32` bounded above, and `lat`/`lon` are `f64`s already range-checked. The caller's
        // free text is NOT here and never is — it is applied to the response below. That is
        // the property that makes this injection-free by construction rather than by
        // escaping, and it is why there is no escaping function anywhere in this file.
        //
        // Unnamed POIs are dropped AFTER the fetch rather than with an `["name"]` filter here:
        // the filter would have to be repeated on every clause, and the saving is not worth a
        // query that reads differently from the tag table it is generated from.
        let overpass = format!(
            "[out:json][timeout:25];\n(\n{clauses});\nout center {};\n",
            MAX_LIMIT * 6
        );

        let body = self.fetch(&self.cfg.overpass_url, Some(overpass)).await?;
        let parsed: Value = serde_json::from_str(&body)
            .map_err(|e| format!("the places backend returned unreadable JSON: {e}"))?;
        let elements = parsed
            .get("elements")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        // Two passes' worth of information in one: everything in range, and whether each one
        // ALSO matched the name terms. Keeping both is what makes the relaxation below
        // possible without a second round trip.
        let mut in_range: Vec<(f64, bool, &Value, f64, f64)> = Vec::new();
        for el in &elements {
            let Some((elat, elon)) = element_coords(el) else {
                continue;
            };
            let tags = el.get("tags").and_then(Value::as_object);
            let name = tags
                .and_then(|t| t.get("name"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if name.is_empty() {
                continue;
            }
            let dist = haversine_m(lat, lon, elat, elon);
            if dist > f64::from(radius) * 1.05 {
                continue;
            }
            let name_hit = if terms.is_empty() {
                true
            } else {
                let hay = fold_name(name);
                let brand = fold_name(
                    tags.and_then(|t| t.get("brand"))
                        .and_then(Value::as_str)
                        .unwrap_or(""),
                );
                terms.iter().any(|t| hay.contains(t) || brand.contains(t))
            };
            in_range.push((dist, name_hit, el, elat, elon));
        }

        let name_hits = in_range.iter().filter(|r| r.1).count();
        let relaxed = relax_name_filter(terms, name_hits, category_fallback);
        let mut results: Vec<(f64, Value)> = in_range
            .into_iter()
            .filter(|(_, hit, _, _, _)| relaxed || *hit)
            .map(|(dist, _, el, elat, elon)| (dist, place_json(el, elat, elon, dist, zone)))
            .collect();
        results.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        let total = results.len();
        Ok(SearchHits {
            places: results.into_iter().take(limit).map(|(_, v)| v).collect(),
            total,
            relaxed,
        })
    }

    /// `place_details`, routed by the id.
    ///
    /// **An id names a source, so there is no provider preference to apply here and no
    /// fallback to make.** An id from one source means nothing to the other: there is no
    /// lookup that turns `node/1375266472` into a record from the paid provider, and none that
    /// turns an opaque paid-provider id into an OSM object. So this dispatches on the id's
    /// form, and when the source an id names is unavailable it says so and stops. Quietly
    /// answering from the other source would return a DIFFERENT PLACE under the id the caller
    /// asked about, which is worse than an error by a wide margin.
    pub async fn details(&self, args: &Value) -> Result<Value, String> {
        let id = args
            .get("id")
            .and_then(Value::as_str)
            .ok_or("id is required; use the `id` of a `places_search` result")?
            .trim();
        let zone = resolve_zone(args.get("timezone").and_then(Value::as_str), &self.cfg);
        let detail = DetailLevel::parse_arg(args)?;
        match PlaceRef::parse(id)? {
            PlaceRef::Google(pid) => self.google_details(id, pid, &zone, detail).await,
            PlaceRef::OpenStreetMap { kind, id: num_id } => {
                self.osm_details(id, kind, num_id, &zone, detail).await
            }
        }
    }

    /// `place_details` against the paid provider.
    ///
    /// # What a `standard` call here buys, which is nothing
    ///
    /// [`crate::places_google::GOOGLE_DETAILS_FIELD_MASK`] names the same field set as
    /// [`crate::places_google::GOOGLE_SEARCH_FIELD_MASK`] — one prefixed, one not — so a
    /// `standard` details call on an id this source produced returns THE SAME VALUES the
    /// search that produced the id already returned, for a second billed call. That is a real
    /// property of the contract rather than an oversight, and it is now said out loud in two
    /// places: the tool description says it, and this path returns
    /// `detail_adds_nothing_here` so a caller can see it on the response it just paid for.
    ///
    /// `rich` is what gives the tool a reason to exist on this source: it is the one way to
    /// get review text for a place already found, without re-running — and re-billing — the
    /// whole search at the dearer mask.
    async fn google_details(
        &self,
        id: &str,
        place_id: &str,
        zone: &Zone,
        detail: DetailLevel,
    ) -> Result<Value, String> {
        let g = self.preferred().map_err(|cause| {
            format!(
                "{id:?} names the source that carries ratings, and this call cannot reach \
                 it: {cause}. Run `places_search` again to get an id from whichever source \
                 is available"
            )
        })?;
        let (body, budget) = g
            .details(&self.http, place_id, detail)
            .await
            .map_err(|e| format!("{e}. Run `places_search` again to get a usable id"))?;
        // NAN for the distance, for the reason the OpenStreetMap path states below.
        let mut out = google_place_json(&body, f64::NAN, zone);
        if !detail.is_rich() {
            out["detail_adds_nothing_here"] = json!(
                "For a record from this source, the standard field set of `place_details` is \
                 the same field set `places_search` already returned, so this call cost a \
                 billed request and added no information. Ask with detail: \"rich\" to get \
                 review text and an editorial summary, which search at the standard level \
                 does not carry."
            );
        }
        let mut report = DetailReport::new(detail);
        report.mask = Some(google_details_field_mask(detail));
        self.annotate(
            &mut out,
            Provider::GooglePlaces,
            None,
            Some(budget),
            &report,
        );
        Ok(out)
    }

    /// `place_details` against OpenStreetMap.
    async fn osm_details(
        &self,
        id: &str,
        kind: &'static str,
        num_id: u64,
        zone: &Zone,
        detail: DetailLevel,
    ) -> Result<Value, String> {
        let overpass = format!("[out:json][timeout:25];\n{kind}({num_id});\nout center;\n");
        let body = self.fetch(&self.cfg.overpass_url, Some(overpass)).await?;
        let parsed: Value = serde_json::from_str(&body)
            .map_err(|e| format!("the places backend returned unreadable JSON: {e}"))?;
        let el = parsed
            .get("elements")
            .and_then(Value::as_array)
            .and_then(|a| a.first())
            .cloned()
            .ok_or_else(|| format!("no place with id {id:?}"))?;
        let (elat, elon) =
            element_coords(&el).ok_or_else(|| format!("place {id:?} carries no coordinates"))?;

        // NAN for the distance: `place_json` emits `distance_m` only when it is finite, and
        // "distance from where?" has no answer here — `place_details` names a place, not a
        // search centre. Emitting 0 would read as "you are standing on it".
        let mut out = place_json(&el, elat, elon, f64::NAN, zone);
        let obj = out.as_object_mut().expect("place_json returns an object");

        // The structured address, when the object's own `addr:*` tags do not carry one. This
        // is the one place a second service is consulted, and it is consulted BY OBJECT ID —
        // no free text, same as everywhere else here.
        if obj.get("address").is_none() {
            let prefix = match kind {
                "node" => 'N',
                "way" => 'W',
                _ => 'R',
            };
            let url = format!(
                "{}/lookup?osm_ids={prefix}{num_id}&format=jsonv2&addressdetails=1",
                self.cfg.nominatim_url
            );
            // A failed address lookup is NOT a failed details call: the hours, which are the
            // reason this tool exists, are already in hand.
            if let Ok(text) = self.fetch(&url, None).await {
                if let Ok(v) = serde_json::from_str::<Value>(&text) {
                    if let Some(first) = v.as_array().and_then(|a| a.first()) {
                        if let Some(display) = first.get("display_name").and_then(Value::as_str) {
                            obj.insert("address".to_string(), json!(display));
                            obj.insert("address_source".to_string(), json!("reverse_lookup"));
                        }
                    }
                }
            }
        }

        // Every tag the object carries, so a turn asking something this module did not think
        // to model ("is there step-free access", "do they take cards") can still answer it.
        if let Some(tags) = el.get("tags") {
            obj.insert("all_tags".to_string(), tags.clone());
        }
        // The free source served this because the id named it, not because anything fell
        // back — so no `provider_fallback_reason`. The budget is reported anyway when a key
        // is configured, so a reader can see the running count from either tool.
        let budget = match self.google.as_ref() {
            Some(g) => g.ledger.peek().await,
            None => None,
        };
        // A `rich` request this source served is announced rather than quietly answered at
        // the standard level — it genuinely has no review text and no editorial summary, and
        // a caller that asked for them is owed the difference between "this place has none"
        // and "the source that answered has none".
        let mut report = DetailReport::new(detail);
        report.served_by_free_source();
        self.annotate(&mut out, Provider::OpenStreetMap, None, budget, &report);
        Ok(out)
    }
}

/// Turn a failed HTTP status into something a turn can act on.
///
/// **A wall of the backend's HTML error page is not an error message.** These services answer
/// overload with a full XHTML document, and echoing three hundred bytes of `<!DOCTYPE html>`
/// into a tool result tells the caller nothing and costs it context. What a caller can act on
/// is the DISTINCTION: 429 and 5xx mean ask again in a moment, 400 means the query was wrong
/// and asking again will not help. So the status is classified here and the body is included
/// only when it is short enough to be a real message rather than a page.
fn describe_http_failure(status: u16, body: &str) -> String {
    let advice = match status {
        429 => "the places backend is rate-limiting this client; wait a minute before asking again",
        502..=504 => {
            "the places backend is overloaded and did not answer in time; this is usually \
             transient, so the same question a minute later often works"
        }
        400 => "the places backend rejected the query as malformed",
        s if s >= 500 => "the places backend failed",
        _ => "the places backend refused the request",
    };
    let looks_like_a_page = body.trim_start().starts_with('<');
    if looks_like_a_page || body.trim().is_empty() {
        format!("HTTP {status}: {advice}")
    } else {
        let snippet: String = body.trim().chars().take(200).collect();
        format!("HTTP {status}: {advice} ({snippet})")
    }
}

/// Validate a place id. **This is the only caller-supplied string that reaches a wire**, and
/// it reaches one only after passing here.
fn parse_place_id(id: &str) -> Result<(&'static str, u64), String> {
    let (kind, rest) = id.split_once('/').ok_or_else(|| {
        format!("malformed id {id:?}; expected node/<n>, way/<n> or relation/<n>")
    })?;
    let kind: &'static str = match kind {
        "node" => "node",
        "way" => "way",
        "relation" => "relation",
        _ => {
            return Err(format!(
                "malformed id {id:?}; expected node/<n>, way/<n> or relation/<n>"
            ))
        }
    };
    let n: u64 = rest
        .parse()
        .map_err(|_| format!("malformed id {id:?}; the part after the slash must be a number"))?;
    Ok((kind, n))
}

/// Which source an id names, decided before anything is looked up.
///
/// The two forms are disjoint by construction and both are CLOSED grammars: an
/// OpenStreetMap object is `node|way|relation/<digits>`, and a paid-provider place is
/// `google/<opaque>`. The prefix is a routing key rather than a label — `place_details` must
/// know which service to ask before it can ask anything, and an opaque token carries nothing
/// that says. OSM ids are unchanged from before the second provider existed, so every id a
/// caller already holds still resolves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaceRef<'a> {
    OpenStreetMap { kind: &'static str, id: u64 },
    Google(&'a str),
}

impl<'a> PlaceRef<'a> {
    pub fn parse(id: &'a str) -> Result<Self, String> {
        let id = id.trim();
        if let Some(rest) = id.strip_prefix("google/") {
            return crate::places_google::validate_google_place_id(rest).map(PlaceRef::Google);
        }
        let (kind, num) = parse_place_id(id)?;
        Ok(PlaceRef::OpenStreetMap { kind, id: num })
    }
}

/// The sentence `places_search` puts after a fallback CAUSE, so that every reason reads the
/// same way and no cause has to know it will be used there. `place_details` deliberately does
/// not use it: there the free source does not answer, it errors.
pub const FELL_BACK: &str = ". This answer came from the free source instead";

/// The sentence a response carries when a `rich` request was answered at `standard` because
/// the source that answered has no such fields.
///
/// It is a CAUSE in the same voice [`PlacesClient::preferred`] produces, and the two tools
/// compose it the same way they compose a provider fallback — so a caller reads one kind of
/// sentence for "you did not get the source you wanted" and the same kind for "you did not
/// get the field set you wanted".
pub const NO_RICH_FROM_THIS_SOURCE: &str =
    "the source that answered carries no review text and no editorial summary, so this answer \
     is the standard field set; a richer one is only available from the source that bills per \
     request";

/// What a response says about how much was asked for, how much was served, and what that
/// cost — carried together so the two tools cannot disagree about them.
///
/// **`requested` and `served` are BOTH reported even when they are equal**, and that is the
/// whole point of the struct. A caller looking at a response with no reviews has to be able
/// to tell *"I did not ask for them"* from *"I asked and this place has none"*, and a single
/// field cannot say both. `mask` is the literal field mask that went out, so "what did I pay
/// for" is answerable from the response itself rather than from this file.
#[derive(Clone, Debug)]
pub struct DetailReport {
    pub requested: DetailLevel,
    pub served: DetailLevel,
    /// The mask that actually left this host, and `None` when no billed call was made —
    /// which is also what makes `cost_tier` conditional. The free source has no mask and no
    /// tier, and inventing one for it would be reporting a price nobody paid.
    pub mask: Option<&'static str>,
    /// Why `served` is below `requested`, when it is.
    pub fallback_reason: Option<String>,
}

impl DetailReport {
    /// A request that has not reached a source yet: served at what was asked for, no mask.
    fn new(requested: DetailLevel) -> Self {
        Self {
            requested,
            served: requested,
            mask: None,
            fallback_reason: None,
        }
    }

    /// Record that the free source answered. It has no rich equivalent, so a `rich` request
    /// is downgraded HERE, with the reason, rather than silently returning a standard record.
    fn served_by_free_source(&mut self) {
        self.served = DetailLevel::Standard;
        self.mask = None;
        if self.requested.is_rich() {
            self.fallback_reason = Some(NO_RICH_FROM_THIS_SOURCE.to_string());
        }
    }

    fn write_into(&self, obj: &mut Map<String, Value>) {
        obj.insert("detail".to_string(), json!(self.served.label()));
        obj.insert(
            "detail_requested".to_string(),
            json!(self.requested.label()),
        );
        if let Some(mask) = self.mask {
            obj.insert("field_mask".to_string(), json!(mask));
            obj.insert("cost_tier".to_string(), json!(self.served.cost_tier()));
        }
        if let Some(reason) = &self.fallback_reason {
            obj.insert("detail_fallback_reason".to_string(), json!(reason));
        }
    }
}

/// What a `places_search` that found nothing says about why, when the reason is knowable.
///
/// **This costs nothing and is computed entirely on this side**, which is the point: the
/// query named no category, so nothing narrowed what was fetched, so a bare business name had
/// no chance of selecting the shop it names. That is a fact about the request, available
/// before any source is asked, and a caller told it can fix the query in one move instead of
/// concluding the place does not exist.
///
/// It fires only when the category table matched NOTHING and the result set is empty. With a
/// category matched, an empty result is a real answer — there is no bakery within 300 m — and
/// explaining it would be noise.
pub const EMPTY_FALLBACK_EXPLANATION: &str =
    "This query matched no category word, so nothing narrowed what was fetched and the words \
     in it were only used to filter what came back. A bare business name selects nothing: the \
     name is not what is searched for, it is what the results are sieved through. Add a \
     category word and search again — \"clothing store Anderson\" rather than \"Anderson\", \
     \"pharmacy Boots\" rather than \"Boots\" — which both narrows the fetch to that kind of \
     place and reaches further from the centre, because the same result ceiling is then spent \
     on that category instead of on whatever happens to be nearest.";

/// One source's answer to `places_search`, before the envelope is put round it.
pub struct SearchHits {
    pub places: Vec<Value>,
    /// How many passed the filters, which can exceed `places.len()` when `limit` cut it.
    pub total: usize,
    pub relaxed: bool,
}

/// **THE NAME FILTER IS RELAXED RATHER THAN ALLOWED TO RETURN NOTHING**, when a category
/// matched and no name did. Shared by both sources so the rule cannot drift into two rules.
///
/// This is not a convenience: without it the most natural phrasing of the question breaks.
/// "cafe near Fountainbridge" leaves `fountainbridge` as a name term — it is not a category
/// word and not a stop word — and no café is CALLED Fountainbridge, so a strict filter answers
/// "there are no cafés near you" for a street with a dozen. The place name in such a query is
/// already expressed by the coordinate the caller passed; insisting it also appear in a venue's
/// name is asking the same question twice and rejecting on the second.
///
/// It is relaxed ONLY when a category matched. With no category the request was for every
/// nearby place, and dropping the name filter there would return all of them — a worse answer
/// than an empty one, because it looks like a result. Either way the response SAYS which
/// happened, in `name_filter_relaxed`.
pub fn relax_name_filter(terms: &[String], name_hits: usize, category_fallback: bool) -> bool {
    !terms.is_empty() && name_hits == 0 && !category_fallback
}

/// The paid provider's half of `places_search`: filter by name on THIS side, rank by distance.
///
/// The provider already restricted the result set to the circle, so there is no radius test
/// here — but the distance is still computed, because that API does not return one and
/// `distance_m` is part of this server's contract on both paths.
pub(crate) fn google_hits(
    body: &Value,
    lat: f64,
    lon: f64,
    limit: usize,
    terms: &[String],
    category_fallback: bool,
    zone: &Zone,
) -> SearchHits {
    let places = body
        .get("places")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let scored: Vec<(f64, bool, &Value)> = places
        .iter()
        .filter(|p| {
            p.get("displayName")
                .and_then(|d| d.get("text"))
                .and_then(Value::as_str)
                .is_some_and(|n| !n.is_empty())
        })
        .map(|p| {
            (
                google_distance(p, lat, lon).unwrap_or(f64::NAN),
                google_name_hit(p, terms),
                p,
            )
        })
        .collect();
    let name_hits = scored.iter().filter(|r| r.1).count();
    let relaxed = relax_name_filter(terms, name_hits, category_fallback);
    let mut kept: Vec<(f64, Value)> = scored
        .into_iter()
        .filter(|(_, hit, _)| relaxed || *hit)
        .map(|(dist, _, p)| (dist, google_place_json(p, dist, zone)))
        .collect();
    kept.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let total = kept.len();
    SearchHits {
        places: kept.into_iter().take(limit).map(|(_, v)| v).collect(),
        total,
        relaxed,
    }
}

fn num(args: &Value, key: &str) -> Option<f64> {
    match args.get(key) {
        Some(Value::Number(n)) => n.as_f64(),
        // A model that has been told "number" still sends "55.9435" often enough that
        // rejecting it would be a worse tool, and a string that does not parse is still
        // rejected below.
        Some(Value::String(s)) => s.trim().parse().ok(),
        _ => None,
    }
}

/// A node has `lat`/`lon`; a way or relation fetched with `out center` has a `center` object.
fn element_coords(el: &Value) -> Option<(f64, f64)> {
    if let (Some(lat), Some(lon)) = (
        el.get("lat").and_then(Value::as_f64),
        el.get("lon").and_then(Value::as_f64),
    ) {
        return Some((lat, lon));
    }
    let c = el.get("center")?;
    Some((
        c.get("lat").and_then(Value::as_f64)?,
        c.get("lon").and_then(Value::as_f64)?,
    ))
}

/// Build one place record.
///
/// **Every optional field is OMITTED when the tag is absent, never emitted empty.** OSM tagging
/// is uneven by nature — the same street has a café with a phone number and website and one
/// next door with neither — and an empty string or a null in `phone` reads to a caller as "this
/// place has no phone", which is a claim the data does not support. A missing key says only
/// that nobody has recorded it, which is the truth.
fn place_json(el: &Value, lat: f64, lon: f64, dist_m: f64, zone: &Zone) -> Value {
    let kind = el.get("type").and_then(Value::as_str).unwrap_or("node");
    let id = el.get("id").and_then(Value::as_u64).unwrap_or(0);
    let empty = Map::new();
    let tags = el
        .get("tags")
        .and_then(Value::as_object)
        .unwrap_or(&empty)
        .clone();
    let t = |k: &str| {
        tags.get(k)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
    };

    let mut out = Map::new();
    // A STABLE ID ACROSS BOTH TOOLS: `place_details` takes exactly this string back. The
    // `node|way|relation/<n>` form is ALSO what routes the id back to this source — see
    // [`PlaceRef::parse`] — so it is unchanged by the arrival of a second provider.
    out.insert("id".to_string(), json!(format!("{kind}/{id}")));
    // WHICH SOURCE SAID THIS. Not a provider name in the tool surface (the KEY is `provider`
    // on every path); a value, so that a caller seeing no `rating` here can tell "no rating
    // exists" from "this source has none". See the module docs.
    out.insert(
        "provider".to_string(),
        json!(Provider::OpenStreetMap.label()),
    );
    out.insert("name".to_string(), json!(t("name").unwrap_or("")));
    out.insert(
        "coordinates".to_string(),
        json!({"latitude": lat, "longitude": lon}),
    );
    if dist_m.is_finite() {
        out.insert("distance_m".to_string(), json!(dist_m.round() as i64));
    }

    // Category, from whichever of the four keys carries it.
    for key in ["amenity", "shop", "leisure", "tourism"] {
        if let Some(v) = t(key) {
            out.insert("category".to_string(), json!(v));
            break;
        }
    }
    if let Some(v) = t("cuisine") {
        out.insert("cuisine".to_string(), json!(v));
    }

    // Address from the object's own tags, when it has enough of them to be useful.
    let street = t("addr:street");
    let housenumber = t("addr:housenumber");
    let city = t("addr:city");
    let postcode = t("addr:postcode");
    if street.is_some() || postcode.is_some() {
        let mut line = String::new();
        if let (Some(n), Some(s)) = (housenumber, street) {
            line.push_str(&format!("{n} {s}"));
        } else if let Some(s) = street {
            line.push_str(s);
        }
        for e in [city, postcode].into_iter().flatten() {
            if !line.is_empty() {
                line.push_str(", ");
            }
            line.push_str(e);
        }
        if !line.is_empty() {
            out.insert("address".to_string(), json!(line));
            out.insert("address_source".to_string(), json!("tags"));
        }
    }
    for (key, field) in [
        ("addr:street", "street"),
        ("addr:housenumber", "housenumber"),
        ("addr:city", "city"),
        ("addr:postcode", "postcode"),
    ] {
        if let Some(v) = t(key) {
            out.insert(field.to_string(), json!(v));
        }
    }

    for (keys, field) in [
        (["phone", "contact:phone"], "phone"),
        (["website", "contact:website"], "website"),
    ] {
        if let Some(v) = keys.iter().find_map(|k| t(k)) {
            out.insert(field.to_string(), json!(v));
        }
    }
    if let Some(v) = t("wheelchair") {
        out.insert("wheelchair".to_string(), json!(v));
    }

    // THE TWO HOURS FIELDS. Both, or neither.
    if let Some(raw) = t("opening_hours") {
        out.insert("opening_hours_raw".to_string(), json!(raw));
        out.insert("opening_hours".to_string(), hours_json(raw, zone));
    }
    // NOTE what is not here: no `rating`, no `rating_count`, not even set to null. This
    // source has none and never will; the record says which source it is, so the absence is
    // readable rather than ambiguous. See the module docs.
    Value::Object(out)
}

/// Great-circle distance in metres.
pub(crate) fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dp = (lat2 - lat1).to_radians();
    let dl = (lon2 - lon1).to_radians();
    let a = (dp / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dl / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().asin()
}

// ---------------------------------------------------------------------------------------
// The advertised tool surface
// ---------------------------------------------------------------------------------------

/// The two tools, as a closed enum.
///
/// Same shape as `BuildOp`: `tools/call` dispatches a NAME onto this, and a name that is not
/// one of these is an error rather than anything else. The names carry no provider — see the
/// module docs for why that is load-bearing rather than stylistic.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlacesTool {
    Search,
    Details,
}

impl PlacesTool {
    pub const ALL: [PlacesTool; 2] = [PlacesTool::Search, PlacesTool::Details];

    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "places_search" => Some(PlacesTool::Search),
            "place_details" => Some(PlacesTool::Details),
            _ => None,
        }
    }

    pub fn tool_name(&self) -> &'static str {
        match self {
            PlacesTool::Search => "places_search",
            PlacesTool::Details => "place_details",
        }
    }

    pub fn description(&self) -> &'static str {
        match self {
            PlacesTool::Search => {
                "Find places near a coordinate and report their opening hours and ratings. \
                 Takes a free-text query (\"cafe\", \"pharmacy\", \"Söderberg bakery\"), a \
                 latitude, a longitude and a radius in metres. Returns each place's stable id, \
                 name, address, coordinates, distance, and whatever of phone, website, \
                 category, rating and opening hours is recorded for it. Opening hours come \
                 back in two fields: `opening_hours_raw` (the source string) and \
                 `opening_hours` (per-weekday intervals plus an `open_now` boolean evaluated \
                 in a named timezone). A rating comes back as `rating` and `rating_count` \
                 together or not at all. Results are served from one of two data sources and \
                 EVERY result names its own in a `provider` field: they differ in coverage — \
                 one has no ratings at all and thinner opening hours — so a missing `rating` \
                 means \"not available from the source that answered\", which is not the same \
                 claim as \"this place is unrated\". When the answer did not come from the \
                 preferred source, `provider_fallback_reason` says why in a sentence. Coverage \
                 is counted on every response: `with_opening_hours`, `without_opening_hours`, \
                 `with_rating` and `without_rating`. If the query contains a place or street \
                 name that matches no venue name, the name filter is dropped and \
                 `name_filter_relaxed` is true — the results are then everything in the \
                 category within the radius. A QUERY WITH NO CATEGORY WORD IN IT selects \
                 nothing to fetch and normally returns nothing at all; when that happens the \
                 response says so in `no_results_explanation` rather than leaving an empty \
                 list to be read as \"there is no such place\". Set `detail` to \"rich\" to \
                 also get review text and an editorial summary, at a materially higher cost \
                 per call and against a separate, much smaller allowance; every response says \
                 which level it served in `detail`, which level was asked for in \
                 `detail_requested`, and — when a billed source answered — the exact field \
                 set it paid for in `field_mask` and its price tier in `cost_tier`."
            }
            PlacesTool::Details => {
                "Get the fullest record for one place, by the `id` of a `places_search` \
                 result — pass the id back EXACTLY as it was given, since it also says which \
                 data source the record came from and that source is the only one that can \
                 resolve it. Returns everything search returns, and for some sources a \
                 looked-up postal address when the place carries none of its own plus every \
                 raw tag recorded for it. Opening hours come back in both the raw and parsed \
                 forms; when the raw value cannot be parsed, `opening_hours.parsed` is false \
                 with a reason and `open_now` is null — the raw value is still returned. If \
                 the source an id names is unavailable this call fails rather than answering \
                 from the other one, because the other one has no record under that id: run \
                 `places_search` again to get a usable id. \
                 FOR A RECORD FROM SOME SOURCES A `standard` CALL HERE ADDS NOTHING: the \
                 source that carries ratings answers this tool with the same field set it \
                 answered the search with, so calling it at the default level spends a \
                 billed request and returns values the caller already has — the response \
                 says so in `detail_adds_nothing_here` when it happens. What that source \
                 does have to add is `detail: \"rich\"`, which returns review text and an \
                 editorial summary for ONE place without re-running, and re-paying for, the \
                 whole search at the dearer field set. Reviews arrive with their author and \
                 a `source_url`, and both must travel with any of that text that is \
                 repeated to a person."
            }
        }
    }

    /// The advertised JSON Schema.
    pub fn input_schema(&self) -> Value {
        match self {
            PlacesTool::Search => json!({
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "What to look for. ALWAYS INCLUDE A CATEGORY WORD (\"cafe\", \"pharmacy\", \"supermarket\", \"clothing store\"); a name may follow it. Only the category word selects what is fetched — a bare business name selects NOTHING and reliably returns an empty result, because the name is not searched for, it is only used to sieve what came back. \"clothing store Anderson\" works where \"Anderson\" finds nothing, and reaches further from the centre as well."
                    },
                    "latitude": {"type": "number", "description": "Centre of the search, -90 to 90."},
                    "longitude": {"type": "number", "description": "Centre of the search, -180 to 180."},
                    "radius_m": {
                        "type": "number",
                        "description": "Search radius in metres. Default 1000, maximum 20000."
                    },
                    "limit": {"type": "number", "description": "Maximum places to return. Default 15, maximum 50."},
                    "detail": {
                        "type": "string",
                        "enum": ["standard", "rich"],
                        "default": "standard",
                        "description": "How much to fetch per place. \"standard\" (the default) returns the fields listed above. \"rich\" also returns review text and, where one exists, an editorial summary — and COSTS MATERIALLY MORE PER CALL, against a separate and much smaller daily allowance that is reported as `rich_budget`. Ask for it only when the question needs what people said rather than how they scored it, and pair it with a small `limit`: it returns up to five reviews for EVERY result, so a rich search over fifteen places is a great deal of prose. Reviews carry display obligations — each one arrives with its author and a `source_url`, and those must travel with any of the text that is repeated to a person."
                    },
                    "timezone": {
                        "type": "string",
                        "description": "IANA timezone name to evaluate `open_now` in, e.g. \"Europe/London\". Defaults to the host's zone; whichever is used is named in the response."
                    }
                },
                "required": ["query", "latitude", "longitude"],
                "additionalProperties": false,
            }),
            PlacesTool::Details => json!({
                "type": "object",
                "properties": {
                    "id": {
                        "type": "string",
                        "description": "The `id` of a `places_search` result, passed back verbatim. Ids are opaque: do not construct, edit or guess one."
                    },
                    "detail": {
                        "type": "string",
                        "enum": ["standard", "rich"],
                        "default": "standard",
                        "description": "How much to fetch. \"standard\" (the default) is the field set search already returned — see the tool description before spending a call on it. \"rich\" adds review text and, where one exists, an editorial summary; it costs materially more per call, against the separate allowance reported as `rich_budget`, and is the reason to call this tool at all for a place search has already returned."
                    },
                    "timezone": {
                        "type": "string",
                        "description": "IANA timezone name to evaluate `open_now` in. Defaults to the host's zone; whichever is used is named in the response."
                    }
                },
                "required": ["id"],
                "additionalProperties": false,
            }),
        }
    }
}

/// Run one tool call.
pub async fn run_places_tool(
    client: &PlacesClient,
    tool: PlacesTool,
    args: &Value,
) -> Result<Value, String> {
    match tool {
        PlacesTool::Search => client.search(args).await,
        PlacesTool::Details => client.details(args).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn iv(s: &str, e: &str) -> Interval {
        Interval {
            start: parse_clock(s).unwrap(),
            end: parse_clock(e).unwrap(),
        }
    }

    // ---- the hours parser ---------------------------------------------------------

    #[test]
    fn simple_weekday_range() {
        let h = parse_opening_hours("Mo-Fr 08:00-18:00").expect("a simple range parses");
        assert!(!h.always_open);
        for d in 0..5 {
            assert_eq!(h.days[d], vec![iv("08:00", "18:00")], "day {d}");
        }
        assert!(h.days[5].is_empty(), "Saturday is closed");
        assert!(h.days[6].is_empty(), "Sunday is closed");
        // 07:00 on a Thursday — the question the two-field shape exists to answer.
        assert!(!h.open_at(3, 7 * 60));
        assert!(h.open_at(3, 9 * 60));
        assert!(!h.open_at(5, 9 * 60), "Saturday morning is shut");
    }

    #[test]
    fn multi_day_list() {
        let h = parse_opening_hours("Mo-Fr 08:00-18:00; Sa,Su 09:00-17:00; PH off")
            .expect("the canonical two-rule form parses");
        assert_eq!(h.days[0], vec![iv("08:00", "18:00")]);
        assert_eq!(h.days[5], vec![iv("09:00", "17:00")]);
        assert_eq!(h.days[6], vec![iv("09:00", "17:00")]);
        // `PH off` is RECOGNISED and FLAGGED rather than applied — there is no holiday
        // calendar here, and pretending otherwise is the guess this design refuses.
        assert!(h.public_holidays_unevaluated);
        assert!(h.open_at(6, 10 * 60), "open Sunday morning");
        assert!(!h.open_at(6, 18 * 60), "shut by six on Sunday");
    }

    #[test]
    fn comma_separated_days_and_a_lunch_break() {
        let h = parse_opening_hours("Mo,We,Fr 09:00-12:00,13:00-17:30").expect("parses");
        assert_eq!(
            h.days[0],
            vec![iv("09:00", "12:00"), iv("13:00", "17:30")],
            "Monday has two spans"
        );
        assert!(h.days[1].is_empty(), "Tuesday is not listed");
        assert_eq!(h.days[2].len(), 2);
        assert!(!h.open_at(0, 12 * 60 + 30), "shut over lunch");
        assert!(h.open_at(0, 13 * 60 + 30));
    }

    #[test]
    fn closed_on_one_day() {
        let h = parse_opening_hours("Mo-Su 10:00-20:00; Tu off").expect("parses");
        assert_eq!(h.days[0], vec![iv("10:00", "20:00")]);
        assert!(
            h.days[1].is_empty(),
            "Tuesday's later `off` rule overrides the range"
        );
        assert_eq!(h.days[2], vec![iv("10:00", "20:00")]);
        assert!(!h.open_at(1, 12 * 60), "shut all day Tuesday");
    }

    #[test]
    fn twenty_four_hour_venue() {
        let h = parse_opening_hours("24/7").expect("24/7 parses");
        assert!(h.always_open);
        for d in 0..7 {
            assert_eq!(h.days[d], vec![iv("00:00", "24:00")], "day {d}");
            assert!(h.open_at(d, 3 * 60), "open at 03:00 on day {d}");
        }
    }

    #[test]
    fn spans_past_midnight() {
        let h = parse_opening_hours("Fr-Sa 20:00-02:00").expect("parses");
        let span = iv("20:00", "02:00");
        assert!(span.crosses_midnight());
        assert!(h.open_at(4, 23 * 60), "Friday 23:00");
        assert!(
            h.open_at(5, 60),
            "Saturday 01:00 — still inside FRIDAY's span, which is the whole point"
        );
        assert!(h.open_at(6, 1), "Sunday 00:01 — inside SATURDAY's span");
        assert!(
            !h.open_at(6, 3 * 60),
            "Sunday 03:00 — Saturday's span ended at 02:00 and Sunday has none of its own"
        );
        assert!(
            !h.open_at(4, 60),
            "Friday 01:00 — Thursday has no span to run into it"
        );
        assert!(!h.open_at(5, 12 * 60), "Saturday lunchtime: not open yet");
    }

    #[test]
    fn no_day_selector_means_every_day() {
        let h = parse_opening_hours("07:00-19:00").expect("parses");
        for d in 0..7 {
            assert_eq!(h.days[d], vec![iv("07:00", "19:00")], "day {d}");
        }
    }

    #[test]
    fn wrapping_day_range() {
        let h = parse_opening_hours("Sa-Mo 11:00-15:00").expect("Sa-Mo wraps the week end");
        assert_eq!(h.days[5], vec![iv("11:00", "15:00")]);
        assert_eq!(h.days[6], vec![iv("11:00", "15:00")]);
        assert_eq!(h.days[0], vec![iv("11:00", "15:00")]);
        assert!(h.days[1].is_empty());
    }

    /// THE CASE THE WHOLE TWO-FIELD DESIGN EXISTS FOR: a value out of scope must fail LOUDLY,
    /// and the caller must still get the raw string back.
    #[test]
    fn unparseable_values_fail_rather_than_guess() {
        for bad in [
            "Jan-Mar 09:00-17:00",              // month selector
            "Mo-Fr sunrise-sunset",             // variable times
            "Su[1] 10:00-14:00",                // nth weekday of the month
            "Mo-Fr 08:00-18:00 open \"ring\"",  // trailing comment
            "week 1-10 Mo 09:00-17:00",         // week selector
            "Mo-Fr 08:00-18:00; Apr 15 closed", // a date
            "",
            "Mo-Fr",     // days, no times
            "Mo 25:00-", // nonsense clock
            "Mo 12:00-12:00",
        ] {
            let err = parse_opening_hours(bad)
                .expect_err(&format!("{bad:?} must be reported as unparseable"));
            assert!(!err.is_empty(), "the failure names what it could not read");
        }

        // ...and the rendered answer for one of them: `parsed` false, a reason, `open_now`
        // NULL rather than false, and the raw string preserved by the caller alongside.
        let zone = Zone {
            tz: chrono_tz::Europe::London,
            name: "Europe/London".to_string(),
            source: "test",
        };
        let raw = "Mo-Fr sunrise-sunset";
        let v = hours_json(raw, &zone);
        assert_eq!(v["parsed"], json!(false));
        assert_eq!(
            v["open_now"],
            Value::Null,
            "a failed parse is NOT reported as closed"
        );
        assert!(v["reason"].as_str().expect("a reason").contains("sunrise"));
        assert_eq!(v["timezone"], json!("Europe/London"));

        // The raw field is emitted from the tags, so prove the pairing at the place level.
        let el = json!({
            "type": "node", "id": 1, "lat": 55.9, "lon": -3.2,
            "tags": {"name": "Nowhere", "amenity": "cafe", "opening_hours": raw}
        });
        let p = place_json(&el, 55.9, -3.2, 10.0, &zone);
        assert_eq!(
            p["opening_hours_raw"],
            json!(raw),
            "the raw string survives"
        );
        assert_eq!(p["opening_hours"]["parsed"], json!(false));
    }

    /// An ABSENT field is absent — no key, no null, no empty string.
    #[test]
    fn absent_hours_emit_no_hours_fields() {
        let zone = Zone {
            tz: chrono_tz::UTC,
            name: "UTC".to_string(),
            source: "test",
        };
        let el = json!({
            "type": "node", "id": 42, "lat": 55.9, "lon": -3.2,
            "tags": {"name": "Untagged Cafe", "amenity": "cafe"}
        });
        let p = place_json(&el, 55.9, -3.2, 12.0, &zone);
        assert_eq!(p["id"], json!("node/42"));
        assert_eq!(p["category"], json!("cafe"));
        assert!(
            p.get("opening_hours_raw").is_none(),
            "no raw key when the tag is missing"
        );
        assert!(
            p.get("opening_hours").is_none(),
            "no parsed key either — never a null"
        );
        assert!(p.get("phone").is_none(), "an absent phone is omitted");
        assert!(p.get("website").is_none());
        assert!(p.get("address").is_none());
    }

    /// There are no ratings in this data source and nothing here may imply otherwise.
    #[test]
    fn no_rating_field_is_ever_emitted() {
        let zone = Zone {
            tz: chrono_tz::UTC,
            name: "UTC".to_string(),
            source: "test",
        };
        let el = json!({
            "type": "way", "id": 7, "center": {"lat": 1.0, "lon": 2.0},
            "tags": {"name": "Anywhere", "amenity": "restaurant", "opening_hours": "24/7"}
        });
        let p = place_json(&el, 1.0, 2.0, 5.0, &zone);
        for forbidden in ["rating", "rating_count", "review_count", "stars", "score"] {
            assert!(
                p.get(forbidden).is_none(),
                "{forbidden} must not appear, not even as null"
            );
        }
        assert_eq!(p["id"], json!("way/7"), "a way is addressed by way/<id>");
    }

    // ---- the naming rule ----------------------------------------------------------

    /// **The provider must not be nameable from the tool surface.** A second provider lands
    /// behind these same names and the allowlist argv must not change when it does; a caller
    /// that has learned to read `osm_id` would make that impossible.
    #[test]
    fn nothing_in_the_advertised_surface_names_a_provider() {
        let mut blob = String::new();
        for t in PlacesTool::ALL {
            blob.push_str(t.tool_name());
            blob.push(' ');
            blob.push_str(t.description());
            blob.push(' ');
            blob.push_str(&t.input_schema().to_string());
            blob.push(' ');
        }
        let zone = Zone {
            tz: chrono_tz::UTC,
            name: "UTC".to_string(),
            source: "test",
        };
        let el = json!({
            "type": "node", "id": 1, "lat": 1.0, "lon": 1.0,
            "tags": {"name": "X", "amenity": "cafe", "opening_hours": "Mo-Fr 09:00-17:00"}
        });
        // Field NAMES only: a tag VALUE could legitimately contain anything.
        let p = place_json(&el, 1.0, 1.0, 1.0, &zone);
        for k in p.as_object().expect("object").keys() {
            blob.push_str(k);
            blob.push(' ');
        }
        for k in p["opening_hours"].as_object().expect("object").keys() {
            blob.push_str(k);
            blob.push(' ');
        }
        let lower = blob.to_lowercase();
        for banned in [
            "osm",
            "overpass",
            "nominatim",
            "openstreetmap",
            "open street map",
        ] {
            assert!(
                !lower.contains(banned),
                "the advertised surface must not name a provider, found {banned:?} in: {blob}"
            );
        }
    }

    // ---- the second source, seen from this side ------------------------------------

    /// The shipped record must SAY which source it came from. Without it a caller seeing no
    /// `rating` cannot tell "this place is unrated" from "the source that answered has no
    /// ratings in it", and those call for different next moves.
    #[test]
    fn every_record_names_the_source_that_produced_it() {
        let zone = Zone {
            tz: chrono_tz::UTC,
            name: "UTC".to_string(),
            source: "test",
        };
        let el = json!({
            "type": "node", "id": 42, "lat": 1.0, "lon": 1.0,
            "tags": {"name": "X", "amenity": "cafe"}
        });
        assert_eq!(
            place_json(&el, 1.0, 1.0, 1.0, &zone)["provider"],
            json!("openstreetmap")
        );
        assert_eq!(Provider::OpenStreetMap.label(), "openstreetmap");
        assert_eq!(Provider::GooglePlaces.label(), "google_places");
    }

    /// The `provider` field is a VALUE, not a name in the tool surface. That distinction is
    /// the whole reason a second source costs no containment battery, so it is asserted
    /// rather than left to the sibling test's phrasing: the KEY is the same string on both
    /// paths, and neither label appears in any tool name, description or schema.
    #[test]
    fn the_provider_is_a_value_and_never_part_of_the_surface() {
        let mut surface = String::new();
        for t in PlacesTool::ALL {
            surface.push_str(t.tool_name());
            surface.push(' ');
            surface.push_str(t.description());
            surface.push(' ');
            surface.push_str(&t.input_schema().to_string());
            surface.push(' ');
        }
        let lower = surface.to_lowercase();
        for label in [
            Provider::OpenStreetMap.label(),
            Provider::GooglePlaces.label(),
            "google",
        ] {
            assert!(
                !lower.contains(label),
                "the advertised surface must not name a source, found {label:?}"
            );
        }
    }

    /// One table, both sources: adding a category has to serve both or say it cannot.
    #[test]
    fn the_category_table_carries_well_formed_types_for_the_second_source() {
        let mut expressible = 0;
        for c in CATEGORIES {
            let mut seen: Vec<&str> = Vec::new();
            for t in c.google_types {
                assert!(
                    !t.is_empty()
                        && t.bytes()
                            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'),
                    "{}: {t:?} is not a well-formed place type",
                    c.name
                );
                assert!(!seen.contains(t), "{}: {t:?} listed twice", c.name);
                seen.push(t);
            }
            if !c.google_types.is_empty() {
                expressible += 1;
            }
        }
        // The three that genuinely have no equivalent are optician, newsagent and
        // greengrocer. If that count moves, the doc comment on `google_types` moves with it.
        assert_eq!(
            CATEGORIES.len() - expressible,
            3,
            "exactly three categories are known to be inexpressible for the second source"
        );
    }

    #[test]
    fn a_query_selects_types_from_the_same_closed_table_as_the_tag_filters() {
        assert_eq!(
            google_types_for_query("coffee"),
            GoogleTypes::These(vec!["cafe", "coffee_shop"])
        );
        // Two categories in one query union their types, in table order, without duplicates.
        assert_eq!(
            google_types_for_query("pharmacy or chemist supermarket"),
            GoogleTypes::These(vec![
                "supermarket",
                "grocery_store",
                "pharmacy",
                "drugstore"
            ])
        );
        // No category at all: ask for everything nearby, exactly as the tag side falls back.
        assert_eq!(google_types_for_query("Söderberg"), GoogleTypes::Everything);
        // A category this source has no type for is neither an error nor a broader question.
        assert_eq!(google_types_for_query("optician"), GoogleTypes::Unsupported);
        assert_eq!(
            google_types_for_query("newsagent"),
            GoogleTypes::Unsupported
        );
    }

    /// A hostile query must not reach the second source's request either. The types are all
    /// `'static` and come from the table; nothing a caller writes can become one.
    #[test]
    fn a_hostile_query_cannot_reach_the_selected_types() {
        let hostile = "cafe\"]);out:json;/*evil*/ {\"includedTypes\":[\"restaurant\"]}";
        assert_eq!(
            google_types_for_query(hostile),
            GoogleTypes::These(vec!["cafe", "coffee_shop", "restaurant"]),
            "only table values survive; the punctuation is not in the result at all"
        );
    }

    /// An id says which source can resolve it, and the ids this server has always emitted
    /// still resolve to the source that emitted them.
    #[test]
    fn an_id_routes_to_the_source_that_can_resolve_it() {
        assert_eq!(
            PlaceRef::parse("node/1375266472"),
            Ok(PlaceRef::OpenStreetMap {
                kind: "node",
                id: 1375266472
            })
        );
        assert_eq!(
            PlaceRef::parse("way/7"),
            Ok(PlaceRef::OpenStreetMap { kind: "way", id: 7 })
        );
        assert_eq!(
            PlaceRef::parse("google/ChIJexample_1-2"),
            Ok(PlaceRef::Google("ChIJexample_1-2"))
        );
        for bad in [
            "google/",
            "google/../../etc/passwd",
            "google/a?fields=*",
            "elephant/1",
            "1375266472",
            "",
        ] {
            assert!(
                PlaceRef::parse(bad).is_err(),
                "{bad:?} must not route anywhere"
            );
        }
    }

    /// The relax rule is shared, so the two sources cannot answer the same query differently.
    #[test]
    fn the_name_filter_relaxes_on_the_same_rule_for_both_sources() {
        let terms = vec!["fountainbridge".to_string()];
        assert!(
            relax_name_filter(&terms, 0, false),
            "a matched category with no name hit relaxes"
        );
        assert!(
            !relax_name_filter(&terms, 0, true),
            "a query with NO category must not relax into every nearby place"
        );
        assert!(
            !relax_name_filter(&terms, 3, false),
            "name hits mean no relaxing"
        );
        assert!(
            !relax_name_filter(&[], 0, false),
            "no terms, nothing to relax"
        );
    }

    /// The second source's result list goes through the same filtering, ranking and limiting
    /// as the first — the caller must not be able to tell which one ran from the envelope's
    /// shape, only from `provider`.
    #[test]
    fn the_second_sources_results_are_filtered_and_ranked_the_same_way() {
        let zone = Zone {
            tz: chrono_tz::UTC,
            name: "UTC".to_string(),
            source: "test",
        };
        let body = json!({"places": [
            {"id": "far", "displayName": {"text": "Far Cafe"},
             "location": {"latitude": 55.9500, "longitude": -3.2081}},
            {"id": "near", "displayName": {"text": "Near Cafe"},
             "location": {"latitude": 55.9436, "longitude": -3.2081}},
            {"id": "nameless", "displayName": {"text": ""},
             "location": {"latitude": 55.9435, "longitude": -3.2081}},
        ]});
        let hits = google_hits(&body, 55.9435, -3.2081, 10, &[], false, &zone);
        assert_eq!(
            hits.total, 2,
            "an unnamed place is dropped, as on the other path"
        );
        assert_eq!(hits.places[0]["name"], json!("Near Cafe"), "nearest first");
        assert_eq!(hits.places[1]["name"], json!("Far Cafe"));
        assert!(hits.places[0]["distance_m"].as_i64().unwrap() < 20);
        assert!(!hits.relaxed);

        // `limit` truncates the returned list but `total` still says how many matched.
        let hits = google_hits(&body, 55.9435, -3.2081, 1, &[], false, &zone);
        assert_eq!(hits.places.len(), 1);
        assert_eq!(hits.total, 2);

        // A name term that matches nothing, with a category matched, relaxes — same rule.
        let terms = vec!["fountainbridge".to_string()];
        let hits = google_hits(&body, 55.9435, -3.2081, 10, &terms, false, &zone);
        assert!(hits.relaxed);
        assert_eq!(hits.places.len(), 2);
    }

    #[test]
    fn tool_names_round_trip() {
        for t in PlacesTool::ALL {
            assert_eq!(PlacesTool::parse(t.tool_name()), Some(t));
        }
        assert_eq!(PlacesTool::parse("places_delete"), None);
        assert_eq!(PlacesTool::parse(""), None);
    }

    // ---- the detail level ----------------------------------------------------------

    /// **THE TOOL SET IS STILL EXACTLY TWO NAMES.** The richer field set arrived as an
    /// argument precisely so that it would not be a third and fourth tool: `capability_args`
    /// carries tool NAMES and never schemas, so a new property moves no argv, so the
    /// committed containment record still speaks for the deployment and this change costs no
    /// live battery. A third name would have cost one.
    #[test]
    fn the_richer_field_set_added_no_tool_name() {
        assert_eq!(PlacesTool::ALL.len(), 2);
        let names: Vec<&str> = PlacesTool::ALL.iter().map(|t| t.tool_name()).collect();
        assert_eq!(names, vec!["places_search", "place_details"]);
        for invented in [
            "places_search_rich",
            "place_details_rich",
            "places_reviews",
            "place_reviews",
        ] {
            assert_eq!(
                PlacesTool::parse(invented),
                None,
                "{invented} must not exist: a third tool name is a containment battery"
            );
        }
        // And it IS on both of the two that do exist.
        for t in PlacesTool::ALL {
            let schema = t.input_schema();
            let detail = &schema["properties"]["detail"];
            assert_eq!(detail["type"], json!("string"), "{}", t.tool_name());
            assert_eq!(detail["enum"], json!(["standard", "rich"]));
            assert_eq!(
                detail["default"],
                json!("standard"),
                "the default must be the cheap answer on both tools"
            );
            assert!(
                !schema["required"]
                    .as_array()
                    .unwrap()
                    .contains(&json!("detail")),
                "an optional parameter, or every existing caller breaks"
            );
        }
    }

    /// The default is the cheap answer, and an unrecognised value is an ERROR rather than a
    /// silent downgrade — a caller that believes it paid for reviews must not be quietly
    /// handed the standard record.
    #[test]
    fn the_detail_argument_defaults_to_standard_and_refuses_nonsense() {
        assert_eq!(
            DetailLevel::parse_arg(&json!({})).unwrap(),
            DetailLevel::Standard,
            "absent means standard"
        );
        assert_eq!(
            DetailLevel::parse_arg(&json!({"detail": null})).unwrap(),
            DetailLevel::Standard
        );
        assert_eq!(
            DetailLevel::parse_arg(&json!({"detail": "standard"})).unwrap(),
            DetailLevel::Standard
        );
        assert_eq!(
            DetailLevel::parse_arg(&json!({"detail": "rich"})).unwrap(),
            DetailLevel::Rich
        );
        // Case and surrounding space are forgiven; anything else is refused.
        assert_eq!(
            DetailLevel::parse_arg(&json!({"detail": "  RICH "})).unwrap(),
            DetailLevel::Rich
        );
        for bad in [
            json!("full"),
            json!("everything"),
            json!(""),
            json!(true),
            json!(2),
        ] {
            let err = DetailLevel::parse_arg(&json!({"detail": bad}))
                .expect_err("an unrecognised detail level must not be answered cheaply");
            assert!(err.contains("standard") && err.contains("rich"), "{err}");
        }
        assert_eq!(DetailLevel::default(), DetailLevel::Standard);
        assert_eq!(DetailLevel::Standard.cost_tier(), "enterprise");
        assert_eq!(DetailLevel::Rich.cost_tier(), "enterprise_atmosphere");
        assert!(!DetailLevel::Standard.is_rich());
        assert!(DetailLevel::Rich.is_rich());
    }

    /// **A caller must be able to tell "I did not ask for reviews" from "I asked and there
    /// are none".** One field cannot say both, so the report carries what was asked for AND
    /// what was served, even when they are the same.
    #[test]
    fn the_response_says_what_was_asked_for_as_well_as_what_it_served() {
        let mut obj = Map::new();
        DetailReport::new(DetailLevel::Standard).write_into(&mut obj);
        assert_eq!(obj["detail"], json!("standard"));
        assert_eq!(obj["detail_requested"], json!("standard"));
        assert!(
            !obj.contains_key("field_mask") && !obj.contains_key("cost_tier"),
            "no billed call was made, so there is no mask and no price to report"
        );
        assert!(!obj.contains_key("detail_fallback_reason"));

        // Served rich by the billed source: the exact mask and its tier are on the response,
        // so "what did I pay for" is answerable without reading the source.
        let mut obj = Map::new();
        let mut r = DetailReport::new(DetailLevel::Rich);
        r.mask = Some(crate::places_google::GOOGLE_SEARCH_FIELD_MASK_RICH);
        r.write_into(&mut obj);
        assert_eq!(obj["detail"], json!("rich"));
        assert_eq!(obj["detail_requested"], json!("rich"));
        assert_eq!(obj["cost_tier"], json!("enterprise_atmosphere"));
        assert!(obj["field_mask"]
            .as_str()
            .unwrap()
            .contains("places.reviews"));

        // A rich request the free source served: downgraded, and SAID SO in the same voice a
        // provider fallback uses.
        let mut obj = Map::new();
        let mut r = DetailReport::new(DetailLevel::Rich);
        r.served_by_free_source();
        r.write_into(&mut obj);
        assert_eq!(obj["detail"], json!("standard"), "what it actually served");
        assert_eq!(obj["detail_requested"], json!("rich"), "what was asked for");
        assert_eq!(
            obj["detail_fallback_reason"],
            json!(NO_RICH_FROM_THIS_SOURCE)
        );
        assert!(!obj.contains_key("cost_tier"), "nothing was billed");

        // A STANDARD request the free source served falls back on nothing, so it explains
        // nothing — the caller got exactly what it asked for.
        let mut obj = Map::new();
        let mut r = DetailReport::new(DetailLevel::Standard);
        r.served_by_free_source();
        r.write_into(&mut obj);
        assert!(!obj.contains_key("detail_fallback_reason"));
    }

    /// The explanation names the fix in words a caller can act on without reading this file:
    /// that a category word is what selects, and that a bare name selects nothing.
    #[test]
    fn the_empty_result_explanation_says_what_to_do_instead() {
        let e = EMPTY_FALLBACK_EXPLANATION;
        assert!(e.contains("category word"), "{e}");
        assert!(e.contains("bare business name"), "{e}");
        assert!(
            e.contains("clothing store Anderson"),
            "an example beats a rule: {e}"
        );
        // And the schema says it too, so a caller never has to make the failing call first.
        let q = PlacesTool::Search.input_schema()["properties"]["query"]["description"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(q.contains("CATEGORY WORD"), "{q}");
        assert!(
            q.contains("selects NOTHING"),
            "the schema must say it outright: {q}"
        );
    }

    // ---- query handling -----------------------------------------------------------

    #[test]
    fn categories_come_from_the_closed_table() {
        assert_eq!(
            categories_for_query("cafe")
                .iter()
                .map(|c| c.name)
                .collect::<Vec<_>>(),
            vec!["cafe"]
        );
        assert!(categories_for_query("is the PHARMACY open")
            .iter()
            .any(|c| c.name == "pharmacy"));
        assert!(categories_for_query("nearest gas station")
            .iter()
            .any(|c| c.name == "fuel"));
        // A query naming nothing known falls back rather than inventing a filter.
        assert!(categories_for_query("Söderberg").is_empty());
        let (filters, names, fallback) = filters_for_query("Söderberg");
        assert!(fallback && names.is_empty());
        assert_eq!(filters, FALLBACK_FILTERS.to_vec());
    }

    /// A live search for `Loudons` returned nothing while `Loudon's Cafe & Bakery` sat eleven
    /// metres from the search centre. Both apostrophes matter: the ASCII one a person types
    /// and the typographic one the data carries.
    #[test]
    fn apostrophes_are_folded_on_both_sides_of_the_name_comparison() {
        assert_eq!(fold_name("Loudon's Cafe & Bakery"), "loudons cafe & bakery");
        assert_eq!(fold_name("L\u{2019}artigiano"), "lartigiano");
        // The term a person types, however they punctuate it, reaches the same key.
        for typed in ["Loudons", "Loudon's", "Loudon\u{2019}s"] {
            let terms = name_terms(typed);
            assert_eq!(terms, vec!["loudons".to_string()], "typed {typed:?}");
            assert!(
                fold_name("Loudon's Cafe & Bakery").contains(&terms[0]),
                "{typed:?} must match the venue"
            );
        }
        // A name that is ONLY an apostrophe folds to nothing and must not become an empty
        // term that matches every venue in the radius.
        assert!(name_terms("''").is_empty());
    }

    /// The precondition for the name-filter relaxation in `search`, which is the difference
    /// between "there are no cafés near you" and a useful answer for the most natural
    /// phrasing of the question.
    #[test]
    fn a_street_name_in_the_query_survives_as_a_name_term() {
        // "cafe near Fountainbridge": the category matches, and the street name is left over
        // as a name term that no café is actually CALLED. `search` relaxes on exactly this
        // shape — a matched category plus zero name hits — rather than returning nothing.
        let q = "cafe near Fountainbridge";
        let (_, names, fallback) = filters_for_query(q);
        assert_eq!(names, vec!["cafe"], "the category still matches");
        assert!(
            !fallback,
            "relaxation is only allowed when a category matched"
        );
        assert_eq!(
            name_terms(q),
            vec!["fountainbridge".to_string()],
            "the street name is what would otherwise filter every result away"
        );

        // With NO category the fallback tag set is in play, and relaxing there would return
        // every shop in the radius — a worse answer than an empty one, because it looks like
        // a result. This asserts the guard's other half is reachable.
        let (_, _, fallback) = filters_for_query("Fountainbridge");
        assert!(
            fallback,
            "no category matched, so relaxation must not apply"
        );
    }

    #[test]
    fn name_terms_drop_category_words_and_stop_words() {
        assert_eq!(name_terms("cafe"), Vec::<String>::new());
        assert_eq!(name_terms("open cafe near me"), Vec::<String>::new());
        assert_eq!(
            name_terms("Söderberg bakery"),
            vec!["söderberg".to_string()]
        );
    }

    /// **NO CALLER TEXT REACHES THE WIRE.** Every byte of a rendered filter comes from a
    /// `'static` constant, so an Overpass query cannot be broken out of — by construction,
    /// not by escaping.
    #[test]
    fn a_hostile_query_cannot_reach_the_rendered_filters() {
        let hostile = r#"cafe"](around:1,0,0);out;//"#;
        let (filters, _, _) = filters_for_query(hostile);
        let rendered: String = filters.iter().map(|f| f.render()).collect();
        assert!(
            !rendered.contains("out;"),
            "caller text leaked into the query: {rendered}"
        );
        assert!(!rendered.contains("//"));
        // It still resolves to the café category, because the word is in there.
        assert!(filters.contains(&TagFilter::eq("amenity", "cafe")));
        // And every rendered byte is accounted for by a constant in the table.
        for f in &filters {
            assert!(
                CATEGORIES
                    .iter()
                    .flat_map(|c| c.filters.iter())
                    .chain(FALLBACK_FILTERS.iter())
                    .any(|k| k == f),
                "a filter appeared that is not in the compile-time table: {f:?}"
            );
        }
    }

    #[test]
    fn place_ids_are_validated_before_they_reach_a_wire() {
        assert_eq!(parse_place_id("node/123").unwrap(), ("node", 123));
        assert_eq!(parse_place_id("way/9").unwrap(), ("way", 9));
        assert_eq!(parse_place_id("relation/4").unwrap(), ("relation", 4));
        for bad in [
            "node/123);out;//",
            "node/-1",
            "nodes/1",
            "1234",
            "node/",
            "/1",
            "node/1 2",
        ] {
            assert!(parse_place_id(bad).is_err(), "{bad:?} must be rejected");
        }
    }

    #[test]
    fn distance_is_sane() {
        // Fountainbridge to roughly a kilometre east.
        let d = haversine_m(55.9435, -3.2081, 55.9435, -3.1921);
        assert!((d - 1000.0).abs() < 60.0, "expected about 1km, got {d}");
        assert_eq!(haversine_m(1.0, 2.0, 1.0, 2.0).round(), 0.0);
    }

    /// A REAL STRING FOUND IN THE WILD, at the exact coordinate this feature was verified
    /// against (The Coffee Cave, Fountainbridge, Edinburgh). It is kept verbatim because it is
    /// the case the two-field design exists for and no synthetic example argues for it as
    /// well: a month-selector dialect, on an ordinary café, 200 m from the test point. A
    /// parser that guessed here would have reported a confident "closed" — the raw string
    /// does contain a `Mo-Fr 07:15-15:00` a regex would happily latch onto — and nothing in
    /// the response would have told the caller it was invented.
    #[test]
    fn the_month_selector_string_that_actually_turned_up_is_refused() {
        let raw = "Jan: Mo-Fr 07:15-15:00; Feb-Mar: Mo-Fr 07:15-15:00; Apr-Aug: Mo-Fr \
                   07:15-15:00; Apr-Aug: Sa,Su 07:15-15:00; Sep-Dec: Mo-Fr 07:15-15:00; \
                   Sep-Dec: Sa,Su 08:30-15:00";
        let err = parse_opening_hours(raw).expect_err("month selectors are out of scope");
        assert!(
            err.contains("Jan"),
            "the failure must name the rule it could not read: {err}"
        );

        let zone = Zone {
            tz: chrono_tz::Europe::London,
            name: "Europe/London".to_string(),
            source: "test",
        };
        let v = hours_json(raw, &zone);
        assert_eq!(v["parsed"], json!(false));
        assert_eq!(
            v["open_now"],
            Value::Null,
            "NOT false — a caller must be able to tell 'unreadable' from 'shut'"
        );
    }

    /// A backend failure must read as a failure a turn can act on, not as an HTML page.
    #[test]
    fn http_failures_are_described_rather_than_dumped() {
        let page = "<?xml version=\"1.0\"?>\n<!DOCTYPE html><html><head><title>504</title>";
        let msg = describe_http_failure(504, page);
        assert!(msg.starts_with("HTTP 504:"));
        assert!(
            msg.contains("transient"),
            "says whether retrying helps: {msg}"
        );
        assert!(
            !msg.contains("DOCTYPE"),
            "the page body is not echoed: {msg}"
        );

        let rate = describe_http_failure(429, "");
        assert!(rate.contains("rate-limiting"), "{rate}");

        // A 400 must NOT suggest retrying — the query is wrong and asking again is rudeness
        // toward a free service.
        let bad = describe_http_failure(400, "line 3: parse error");
        assert!(bad.contains("malformed"), "{bad}");
        assert!(!bad.contains("transient"), "{bad}");
        assert!(
            bad.contains("parse error"),
            "a short, real message IS worth passing through: {bad}"
        );
    }

    #[test]
    fn config_defaults_and_overrides() {
        let d = PlacesConfig::default();
        assert_eq!(d.overpass_url, DEFAULT_OVERPASS_URL);
        assert!(
            d.user_agent.contains("jesse-bridge"),
            "the User-Agent must identify this software: both backends require it"
        );
        assert!(
            d.user_agent.contains("http"),
            "and must carry a route to a human"
        );
        assert_eq!(d.min_interval, Duration::from_millis(1000));
    }
}
