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
//! # The naming rule, which is not negotiable
//!
//! **Nothing a caller can see names a provider.** Not the tool names, not the descriptions,
//! not a field in the output. The backend here is OpenStreetMap — Overpass for nearby search
//! and Nominatim for the address of a specific object — and a second provider is expected
//! behind exactly these names, carrying the ratings OSM does not have. The whole point of the
//! design is that when it lands, `DEFAULT_ALLOWED_TOOLS` and the containment record's
//! `toolset_args` DO NOT CHANGE: adding a provider must not cost a live battery re-run. A
//! provider name leaking into `places_search`'s output shape would make that impossible,
//! because the caller would have learned to depend on it.
//!
//! The `provider` field in a result is therefore a deliberate omission, not an oversight.
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
//! # There are no ratings here
//!
//! OSM carries none, no proxy for one exists in the data, and this module does not emit a
//! `rating` key — not even null. A null rating is worse than a missing one: a caller that sees
//! the key learns the concept exists and may render "0" or "unrated" for a place that is
//! simply outside this provider's coverage. Ratings arrive with the second provider or they do
//! not arrive.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{Datelike, Timelike, Utc};
use serde_json::{json, Map, Value};
use tokio::sync::Mutex;

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

/// A named category: the words a person might use for it, and the tags it lives under.
#[derive(Clone, Copy, Debug)]
pub struct Category {
    /// The category's own name, echoed to the caller as `category`.
    pub name: &'static str,
    /// Words that select this category. Matched as whole words against the lowercased query.
    pub keywords: &'static [&'static str],
    pub filters: &'static [TagFilter],
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
    },
    Category {
        name: "restaurant",
        keywords: &["restaurant", "dinner", "lunch", "bistro", "trattoria"],
        filters: &[TagFilter::eq("amenity", "restaurant")],
    },
    Category {
        name: "fast_food",
        keywords: &[
            "takeaway", "takeout", "fastfood", "burger", "kebab", "chippy",
        ],
        filters: &[TagFilter::eq("amenity", "fast_food")],
    },
    Category {
        name: "pub",
        keywords: &["pub", "tavern", "alehouse"],
        filters: &[TagFilter::eq("amenity", "pub")],
    },
    Category {
        name: "bar",
        keywords: &["bar", "cocktails", "wine bar"],
        filters: &[TagFilter::eq("amenity", "bar")],
    },
    Category {
        name: "nightclub",
        keywords: &["nightclub", "club"],
        filters: &[TagFilter::eq("amenity", "nightclub")],
    },
    Category {
        name: "ice_cream",
        keywords: &["gelato", "icecream"],
        filters: &[TagFilter::eq("amenity", "ice_cream")],
    },
    Category {
        name: "bakery",
        keywords: &["bakery", "baker", "bread", "patisserie"],
        filters: &[TagFilter::eq("shop", "bakery")],
    },
    Category {
        name: "supermarket",
        keywords: &["supermarket", "grocery", "groceries", "grocer"],
        filters: &[TagFilter::eq("shop", "supermarket")],
    },
    Category {
        name: "convenience",
        keywords: &["convenience", "cornershop"],
        filters: &[TagFilter::eq("shop", "convenience")],
    },
    Category {
        name: "deli",
        keywords: &["deli", "delicatessen"],
        filters: &[TagFilter::eq("shop", "deli")],
    },
    Category {
        name: "butcher",
        keywords: &["butcher", "butchers"],
        filters: &[TagFilter::eq("shop", "butcher")],
    },
    Category {
        name: "greengrocer",
        keywords: &["greengrocer", "fruit", "vegetables"],
        filters: &[TagFilter::eq("shop", "greengrocer")],
    },
    Category {
        name: "alcohol",
        keywords: &["offlicence", "liquor", "wine shop", "whisky", "bottleshop"],
        filters: &[TagFilter::eq("shop", "alcohol")],
    },
    Category {
        name: "pharmacy",
        keywords: &["pharmacy", "chemist", "drugstore", "apotheke", "farmacia"],
        filters: &[TagFilter::eq("amenity", "pharmacy")],
    },
    Category {
        name: "doctors",
        keywords: &["doctor", "doctors", "gp", "surgery", "clinic"],
        filters: &[TagFilter::eq("amenity", "doctors")],
    },
    Category {
        name: "dentist",
        keywords: &["dentist", "dental"],
        filters: &[TagFilter::eq("amenity", "dentist")],
    },
    Category {
        name: "hospital",
        keywords: &["hospital", "a&e", "emergency room"],
        filters: &[TagFilter::eq("amenity", "hospital")],
    },
    Category {
        name: "veterinary",
        keywords: &["vet", "vets", "veterinary"],
        filters: &[TagFilter::eq("amenity", "veterinary")],
    },
    Category {
        name: "bank",
        keywords: &["bank"],
        filters: &[TagFilter::eq("amenity", "bank")],
    },
    Category {
        name: "atm",
        keywords: &["atm", "cashpoint", "cash machine"],
        filters: &[TagFilter::eq("amenity", "atm")],
    },
    Category {
        name: "post_office",
        keywords: &["post office", "postoffice", "post"],
        filters: &[TagFilter::eq("amenity", "post_office")],
    },
    Category {
        name: "library",
        keywords: &["library"],
        filters: &[TagFilter::eq("amenity", "library")],
    },
    Category {
        name: "fuel",
        keywords: &["petrol", "fuel", "gas station", "diesel", "filling station"],
        filters: &[TagFilter::eq("amenity", "fuel")],
    },
    Category {
        name: "parking",
        keywords: &["parking", "car park", "carpark"],
        filters: &[TagFilter::eq("amenity", "parking")],
    },
    Category {
        name: "toilets",
        keywords: &["toilet", "toilets", "loo", "restroom", "wc"],
        filters: &[TagFilter::eq("amenity", "toilets")],
    },
    Category {
        name: "cinema",
        keywords: &["cinema", "movies", "movie theater"],
        filters: &[TagFilter::eq("amenity", "cinema")],
    },
    Category {
        name: "theatre",
        keywords: &["theatre", "theater"],
        filters: &[TagFilter::eq("amenity", "theatre")],
    },
    Category {
        name: "place_of_worship",
        keywords: &["church", "mosque", "synagogue", "temple"],
        filters: &[TagFilter::eq("amenity", "place_of_worship")],
    },
    Category {
        name: "museum",
        keywords: &["museum", "gallery"],
        filters: &[TagFilter::eq("tourism", "museum")],
    },
    Category {
        name: "hotel",
        keywords: &["hotel", "hostel", "b&b", "guesthouse"],
        filters: &[TagFilter::matching(
            "tourism",
            "^(hotel|hostel|guest_house|motel)$",
        )],
    },
    Category {
        name: "attraction",
        keywords: &["attraction", "sightseeing", "viewpoint"],
        filters: &[TagFilter::matching(
            "tourism",
            "^(attraction|viewpoint|artwork)$",
        )],
    },
    Category {
        name: "fitness_centre",
        keywords: &["gym", "fitness", "climbing"],
        filters: &[TagFilter::matching(
            "leisure",
            "^(fitness_centre|sports_centre|climbing)$",
        )],
    },
    Category {
        name: "swimming_pool",
        keywords: &["pool", "swimming", "swim"],
        filters: &[TagFilter::matching(
            "leisure",
            "^(swimming_pool|water_park)$",
        )],
    },
    Category {
        name: "park",
        keywords: &["park", "garden", "green space"],
        filters: &[TagFilter::matching("leisure", "^(park|garden)$")],
    },
    Category {
        name: "playground",
        keywords: &["playground", "play park"],
        filters: &[TagFilter::eq("leisure", "playground")],
    },
    Category {
        name: "hairdresser",
        keywords: &["hairdresser", "barber", "haircut", "salon"],
        filters: &[TagFilter::eq("shop", "hairdresser")],
    },
    Category {
        name: "laundry",
        keywords: &["laundry", "launderette", "laundrette", "dry cleaner"],
        filters: &[TagFilter::matching("shop", "^(laundry|dry_cleaning)$")],
    },
    Category {
        name: "doityourself",
        keywords: &["hardware", "diy", "tools"],
        filters: &[TagFilter::matching(
            "shop",
            "^(doityourself|hardware|trade)$",
        )],
    },
    Category {
        name: "books",
        keywords: &["bookshop", "bookstore", "books", "bookseller"],
        filters: &[TagFilter::eq("shop", "books")],
    },
    Category {
        name: "clothes",
        keywords: &["clothes", "clothing", "fashion", "shoes"],
        filters: &[TagFilter::matching("shop", "^(clothes|shoes|boutique)$")],
    },
    Category {
        name: "electronics",
        keywords: &["electronics", "computer", "phone shop"],
        filters: &[TagFilter::matching(
            "shop",
            "^(electronics|computer|mobile_phone)$",
        )],
    },
    Category {
        name: "optician",
        keywords: &["optician", "optometrist", "glasses"],
        filters: &[TagFilter::eq("shop", "optician")],
    },
    Category {
        name: "florist",
        keywords: &["florist", "flowers"],
        filters: &[TagFilter::eq("shop", "florist")],
    },
    Category {
        name: "newsagent",
        keywords: &["newsagent", "newspaper"],
        filters: &[TagFilter::eq("shop", "newsagent")],
    },
    Category {
        name: "school",
        keywords: &["school"],
        filters: &[TagFilter::eq("amenity", "school")],
    },
    Category {
        name: "university",
        keywords: &["university", "campus", "college"],
        filters: &[TagFilter::matching("amenity", "^(university|college)$")],
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
fn fold_name(s: &str) -> String {
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
struct Zone {
    tz: chrono_tz::Tz,
    name: String,
    source: &'static str,
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
    let now = Utc::now().with_timezone(&zone.tz);
    let weekday = now.weekday().num_days_from_monday() as usize;
    let minute = (now.hour() * 60 + now.minute()) as u16;

    match parse_opening_hours(raw) {
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
    /// Serialises ALL outbound requests and holds the time of the last one. One gate covers
    /// both endpoints deliberately — the policy is about the client, and two independent
    /// limiters would let a search and a lookup fire in the same tick.
    gate: Mutex<Option<Instant>>,
    cache: Mutex<HashMap<String, CacheEntry>>,
}

impl PlacesClient {
    pub fn new(cfg: PlacesConfig) -> Result<Arc<Self>, String> {
        let http = reqwest::Client::builder()
            .user_agent(cfg.user_agent.clone())
            .timeout(cfg.http_timeout)
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        Ok(Arc::new(Self {
            cfg,
            http,
            gate: Mutex::new(None),
            cache: Mutex::new(HashMap::new()),
        }))
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

    /// `places_search`.
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

        let (filters, categories, fallback) = filters_for_query(&query);
        let terms = name_terms(&query);

        let mut clauses = String::new();
        for f in &filters {
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

        // THE NAME FILTER IS RELAXED RATHER THAN ALLOWED TO RETURN NOTHING, when a category
        // matched and no name did.
        //
        // This is not a convenience: without it the most natural phrasing of the question
        // breaks. "cafe near Fountainbridge" leaves `fountainbridge` as a name term — it is
        // not a category word and not a stop word — and no café is CALLED Fountainbridge, so
        // a strict filter answers "there are no cafés near you" for a street with a dozen.
        // The place name in such a query is already expressed by the coordinate the caller
        // passed; insisting it also appear in a venue's name is asking the same question
        // twice and rejecting on the second.
        //
        // It is relaxed ONLY when a category matched. With no category the tag set is the
        // broad POI fallback, and dropping the name filter there would return every shop in
        // the radius — a worse answer than an empty one, because it looks like a result.
        // Either way the response SAYS which happened.
        let name_hits = in_range.iter().filter(|r| r.1).count();
        let relaxed = !terms.is_empty() && name_hits == 0 && !fallback;
        let mut results: Vec<(f64, Value)> = in_range
            .into_iter()
            .filter(|(_, hit, _, _, _)| relaxed || *hit)
            .map(|(dist, _, el, elat, elon)| (dist, place_json(el, elat, elon, dist, &zone)))
            .collect();
        results.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        let total = results.len();
        let places: Vec<Value> = results.into_iter().take(limit).map(|(_, v)| v).collect();

        // COVERAGE IS REPORTED, NOT IMPLIED. `opening_hours` is present on some cafés and
        // absent on others, and a caller that cannot see how many of its results carried the
        // field has no way to tell "nothing is open" from "nobody has tagged this street".
        let with_hours = places
            .iter()
            .filter(|p| p.get("opening_hours_raw").is_some())
            .count();

        Ok(json!({
            "query": query,
            "center": {"latitude": lat, "longitude": lon},
            "radius_m": radius,
            "matched_categories": categories,
            "used_fallback_categories": fallback,
            "name_filter_terms": terms,
            "name_filter_relaxed": relaxed,
            "timezone": zone.name,
            "timezone_source": zone.source,
            "total_matches": total,
            "returned": places.len(),
            "with_opening_hours": with_hours,
            "without_opening_hours": places.len().saturating_sub(with_hours),
            "places": places,
        }))
    }

    /// `place_details`.
    pub async fn details(&self, args: &Value) -> Result<Value, String> {
        let id = args
            .get("id")
            .and_then(Value::as_str)
            .ok_or("id is required; use the `id` of a `places_search` result")?
            .trim();
        let (kind, num_id) = parse_place_id(id)?;
        let zone = resolve_zone(args.get("timezone").and_then(Value::as_str), &self.cfg);

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
        let mut out = place_json(&el, elat, elon, f64::NAN, &zone);
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
    // A STABLE ID ACROSS BOTH TOOLS: `place_details` takes exactly this string back.
    out.insert("id".to_string(), json!(format!("{kind}/{id}")));
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
    // NOTE what is not here: no `rating`, no `review_count`, not even set to null. See the
    // module docs.
    Value::Object(out)
}

/// Great-circle distance in metres.
fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
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
                "Find places near a coordinate and report their opening hours. Takes a free-text \
                 query (\"cafe\", \"pharmacy\", \"Söderberg bakery\"), a latitude, a longitude \
                 and a radius in metres. Returns each place's stable id, name, address, \
                 coordinates, distance, and whatever of phone, website, category and opening \
                 hours is recorded for it. Opening hours come back in two fields: \
                 `opening_hours_raw` (the source string) and `opening_hours` (per-weekday \
                 intervals plus an `open_now` boolean evaluated in a named timezone). Coverage \
                 is uneven and the response says so: `with_opening_hours` and \
                 `without_opening_hours` count how many results carried the field. If the \
                 query contains a place or street name that matches no venue name, the name \
                 filter is dropped and `name_filter_relaxed` is true — the results are then \
                 everything in the category within the radius. No ratings are available from \
                 this source."
            }
            PlacesTool::Details => {
                "Get the fullest record for one place, by the `id` of a `places_search` result \
                 (for example \"node/1234567\"). Returns everything search returns, plus a \
                 looked-up postal address when the place has no address tags of its own, and \
                 every raw tag recorded for it. Opening hours come back in both the raw and \
                 parsed forms; when the raw string cannot be parsed, `opening_hours.parsed` is \
                 false with a reason and `open_now` is null — the raw string is still returned."
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
                        "description": "What to look for: a category word (\"cafe\", \"pharmacy\", \"supermarket\") and/or part of a name. Category words select what is fetched; the rest filters by name."
                    },
                    "latitude": {"type": "number", "description": "Centre of the search, -90 to 90."},
                    "longitude": {"type": "number", "description": "Centre of the search, -180 to 180."},
                    "radius_m": {
                        "type": "number",
                        "description": "Search radius in metres. Default 1000, maximum 20000."
                    },
                    "limit": {"type": "number", "description": "Maximum places to return. Default 15, maximum 50."},
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
                        "description": "The `id` of a `places_search` result, e.g. \"node/1234567\"."
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

    #[test]
    fn tool_names_round_trip() {
        for t in PlacesTool::ALL {
            assert_eq!(PlacesTool::parse(t.tool_name()), Some(t));
        }
        assert_eq!(PlacesTool::parse("places_delete"), None);
        assert_eq!(PlacesTool::parse(""), None);
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
