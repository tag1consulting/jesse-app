//! Which source `places` answers from, and what it says when it is not the preferred one.
//!
//! # Why this runs against real servers on loopback rather than a mocked seam
//!
//! The thing under test is a DECISION with money on one side of it: prefer the paid source,
//! fall back to the free one, and say which happened. A mocked HTTP seam would assert that the
//! code called the seam. What has to be asserted instead is what actually leaves this host —
//! the field mask header that sets the price, the API key header, and above all that no
//! caller-authored string is anywhere in the request body — and what comes back when the paid
//! source answers, fails, or is never asked.
//!
//! So both backends are real `axum` servers on `127.0.0.1`, and every assertion about a
//! request is made against the bytes one of them received.
//!
//! Nothing here reaches a real service or spends anything: the base URLs are loopback and the
//! key is a fixture string.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::{
    extract::State,
    http::HeaderMap,
    response::IntoResponse,
    routing::{get, post},
    Router,
};
use jesse_bridge::{
    run_places_tool, ApiKey, GoogleConfig, PlacesClient, PlacesConfig, PlacesTool,
    ProviderPreference, GOOGLE_DETAILS_FIELD_MASK, GOOGLE_DETAILS_FIELD_MASK_RICH,
    GOOGLE_SEARCH_FIELD_MASK, GOOGLE_SEARCH_FIELD_MASK_RICH,
};
use serde_json::{json, Value};

// ---- scratch ----------------------------------------------------------------------------

/// A scratch directory that removes itself, so each test gets its own request ledger.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        let p = std::env::temp_dir().join(format!("jesse-places-provider-{tag}"));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).expect("scratch");
        Self(p)
    }
    fn ledger(&self) -> PathBuf {
        self.0.join("calls.log")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

// ---- what each fake server recorded ------------------------------------------------------

#[derive(Clone, Debug, Default)]
struct Seen {
    /// Every request body this server received, verbatim.
    bodies: Vec<String>,
    /// Every `(field mask, api key)` pair, so the price and the credential are assertable.
    masks: Vec<String>,
    keys: Vec<String>,
    paths: Vec<String>,
}

type Log = Arc<Mutex<Seen>>;

#[derive(Clone)]
struct Fake {
    log: Log,
    /// What to answer with: `Ok(body)` or `Err(status)`.
    reply: Arc<Result<Value, u16>>,
}

/// The stand-in for the paid provider's Nearby Search and Place Details.
async fn start_fake_google(reply: Result<Value, u16>) -> (String, Log) {
    let log: Log = Arc::new(Mutex::new(Seen::default()));
    let state = Fake {
        log: log.clone(),
        reply: Arc::new(reply),
    };
    let app = Router::new()
        .route("/v1/places:searchNearby", post(fake_search))
        .route("/v1/places/:id", get(fake_details))
        .with_state(state);
    (serve(app).await, log)
}

async fn fake_search(
    State(s): State<Fake>,
    headers: HeaderMap,
    body: String,
) -> axum::response::Response {
    record(&s.log, &headers, "searchNearby", Some(body));
    answer(&s.reply)
}

async fn fake_details(
    State(s): State<Fake>,
    axum::extract::Path(id): axum::extract::Path<String>,
    headers: HeaderMap,
) -> axum::response::Response {
    record(&s.log, &headers, &format!("places/{id}"), None);
    answer(&s.reply)
}

fn record(log: &Log, headers: &HeaderMap, path: &str, body: Option<String>) {
    let mut l = log.lock().unwrap();
    l.paths.push(path.to_string());
    if let Some(b) = body {
        l.bodies.push(b);
    }
    for (name, into) in [("x-goog-fieldmask", 0usize), ("x-goog-api-key", 1usize)] {
        let v = headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        if into == 0 {
            l.masks.push(v);
        } else {
            l.keys.push(v);
        }
    }
}

fn answer(reply: &Result<Value, u16>) -> axum::response::Response {
    match reply {
        Ok(v) => axum::Json(v.clone()).into_response(),
        Err(code) => (
            axum::http::StatusCode::from_u16(*code).unwrap(),
            r#"{"error":{"code":500,"status":"INTERNAL","message":"key=SHOULD-NOT-LEAK"}}"#,
        )
            .into_response(),
    }
}

/// The stand-in for the free source's Overpass endpoint. It answers every query with the same
/// one element, which is all these tests need: the assertion is WHICH source answered.
async fn start_fake_overpass() -> (String, Log) {
    let log: Log = Arc::new(Mutex::new(Seen::default()));
    let state = Fake {
        log: log.clone(),
        reply: Arc::new(Ok(json!({"elements": [{
            "type": "node",
            "id": 1375266472,
            "lat": 55.9436,
            "lon": -3.2082,
            "tags": {
                "name": "Loudon's Cafe & Bakery",
                "amenity": "cafe",
                "opening_hours": "Mo-Fr 07:30-17:00; Sa,Su 08:00-17:00",
            }
        }]}))),
    };
    let app = Router::new()
        .route("/api/interpreter", post(fake_search))
        .with_state(state);
    (serve(app).await, log)
}

async fn serve(app: Router) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr: SocketAddr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

// ---- fixtures ----------------------------------------------------------------------------

/// One paid-source record with everything the tool contract asks for: a rating WITH its count,
/// and structured hours.
fn google_body() -> Value {
    json!({"places": [{
        "id": "ChIJFixture",
        "displayName": {"text": "Loudon's Cafe & Bakery", "languageCode": "en"},
        "formattedAddress": "94B Fountainbridge, Edinburgh EH3 9QA, UK",
        "location": {"latitude": 55.9436, "longitude": -3.2082},
        "primaryType": "cafe",
        "rating": 4.4,
        "userRatingCount": 2183,
        "regularOpeningHours": {
            "weekdayDescriptions": ["Monday: 7:30 AM – 5:00 PM"],
            "periods": [{
                "open": {"day": 1, "hour": 7, "minute": 30},
                "close": {"day": 1, "hour": 17, "minute": 0},
            }],
        },
    }]})
}

fn config(overpass: &str, google: Option<GoogleConfig>) -> PlacesConfig {
    PlacesConfig {
        overpass_url: format!("{overpass}/api/interpreter"),
        // Never reached in these tests: `place_details` on an id whose tags carry an address
        // does not consult it, and nothing here asks for one that does not.
        nominatim_url: "http://127.0.0.1:1".to_string(),
        // No politeness delay against a loopback stand-in — the gate is not what is under
        // test and a second per call would only make the suite slow.
        min_interval: Duration::from_millis(0),
        provider_preference: ProviderPreference::Auto,
        google,
        ..PlacesConfig::default()
    }
}

fn google_cfg(base: &str, sc: &Scratch, max_calls: u32) -> GoogleConfig {
    GoogleConfig {
        api_key: ApiKey::new("fixture-key"),
        base_url: format!("{base}/v1"),
        max_calls,
        rich_max_calls: max_calls,
        window: Duration::from_secs(3600),
        ledger: Some(sc.ledger()),
    }
}

fn search_args() -> Value {
    json!({
        "query": "cafe",
        "latitude": 55.9435,
        "longitude": -3.2081,
        "radius_m": 400,
        "timezone": "Europe/London",
    })
}

async fn search(cfg: PlacesConfig) -> Value {
    let client = PlacesClient::new(cfg).expect("client");
    run_places_tool(&client, PlacesTool::Search, &search_args())
        .await
        .expect("search must answer")
}

// ---- the four selection cases ------------------------------------------------------------

/// **No key configured.** The free source answers, the response says so, and it says WHY —
/// a caller that sees no ratings is owed the difference between "there are none for this
/// place" and "this deployment has no key for the source that has them".
#[tokio::test]
async fn with_no_key_the_free_source_answers_and_the_response_says_why() {
    let (overpass, seen) = start_fake_overpass().await;
    let out = search(config(&overpass, None)).await;

    assert_eq!(out["provider"], json!("openstreetmap"));
    assert_eq!(out["places"][0]["provider"], json!("openstreetmap"));
    let why = out["provider_fallback_reason"].as_str().expect("a reason");
    assert!(why.contains("no API key is configured"), "{why}");
    assert!(
        out.get("budget").is_none(),
        "there is no budget to report when there is no paid source"
    );
    assert!(
        out.get("attribution").is_none(),
        "the free source carries no attribution requirement"
    );
    // The result is a real one, not an empty envelope.
    assert_eq!(out["returned"], json!(1));
    assert_eq!(out["with_opening_hours"], json!(1));
    assert_eq!(out["with_rating"], json!(0), "this source has no ratings");
    assert!(out["places"][0].get("rating").is_none());
    assert_eq!(seen.lock().unwrap().bodies.len(), 1);
}

/// **Key configured and the call succeeds.** The paid source answers, the record carries a
/// rating WITH its count, the budget is reported, and — the two assertions that matter most —
/// the field mask is exactly the one that sets the price, and no caller-authored string is
/// anywhere in the request body.
#[tokio::test]
async fn with_a_key_the_paid_source_answers_and_carries_ratings() {
    let sc = Scratch::new("paid-ok");
    let (overpass, osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_body())).await;
    let out = search(config(&overpass, Some(google_cfg(&google, &sc, 10)))).await;

    assert_eq!(out["provider"], json!("google_places"));
    assert_eq!(out["places"][0]["provider"], json!("google_places"));
    assert!(
        out.get("provider_fallback_reason").is_none(),
        "nothing fell back, so nothing to explain"
    );
    assert_eq!(out["places"][0]["rating"], json!(4.4));
    assert_eq!(out["places"][0]["rating_count"], json!(2183));
    assert_eq!(out["with_rating"], json!(1));
    assert_eq!(out["places"][0]["id"], json!("google/ChIJFixture"));
    assert_eq!(out["attribution"], json!("Google Maps"));
    assert_eq!(
        out["budget"],
        json!({"used": 1, "limit": 10, "window_seconds": 3600})
    );

    // The free source was never asked.
    assert!(osm_seen.lock().unwrap().bodies.is_empty());

    let s = seen.lock().unwrap();
    assert_eq!(s.masks, vec![GOOGLE_SEARCH_FIELD_MASK.to_string()]);
    assert_eq!(s.keys, vec!["fixture-key".to_string()]);

    // NO CALLER-AUTHORED STRING ON THE WIRE. The query word, and the punctuation a hostile
    // one would carry, are applied to the response on this side and are not in the request.
    let body = &s.bodies[0];
    let sent: Value = serde_json::from_str(body).expect("a JSON body");
    assert_eq!(sent["includedTypes"], json!(["cafe", "coffee_shop"]));
    assert_eq!(
        sent["locationRestriction"]["circle"]["radius"],
        json!(400.0)
    );
    assert!(
        sent.get("textQuery").is_none(),
        "the free-text search endpoint is not used and its parameter is never sent"
    );
    assert!(
        !body.contains("cafe\"") || sent["includedTypes"].is_array(),
        "the only occurrence of the query word is as a table-supplied type"
    );
}

/// **Key configured and the call fails.** The free source answers instead, the response names
/// the failure, and the provider's error body — which can quote request parameters back — is
/// not echoed into the turn.
#[tokio::test]
async fn a_failed_paid_call_falls_back_to_the_free_source_and_says_so() {
    let sc = Scratch::new("paid-fail");
    let (overpass, osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Err(500)).await;
    let out = search(config(&overpass, Some(google_cfg(&google, &sc, 10)))).await;

    assert_eq!(out["provider"], json!("openstreetmap"));
    assert_eq!(out["places"][0]["provider"], json!("openstreetmap"));
    let why = out["provider_fallback_reason"].as_str().expect("a reason");
    assert!(
        why.contains("HTTP 500"),
        "the reason names the failure: {why}"
    );
    assert!(
        !why.contains("SHOULD-NOT-LEAK"),
        "the provider's error body must not reach a turn: {why}"
    );
    // The paid source was asked once and the free one answered.
    assert_eq!(seen.lock().unwrap().bodies.len(), 1);
    assert_eq!(osm_seen.lock().unwrap().bodies.len(), 1);
    assert_eq!(out["returned"], json!(1));
    // A CALL THAT FAILED STILL COUNTS. It reached the provider, so it may have been billed.
    assert_eq!(out["budget"]["used"], json!(1));
}

/// **The budget cap is tripped.** The free source answers, the reason names the ceiling and
/// the window, and the paid source is never contacted at all.
#[tokio::test]
async fn a_spent_budget_falls_back_without_contacting_the_paid_source() {
    let sc = Scratch::new("budget-spent");
    let (overpass, osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_body())).await;
    let cfg = google_cfg(&google, &sc, 2);

    // Spend the whole window.
    for expected in ["google_places", "google_places"] {
        let out = search(config(&overpass, Some(cfg.clone()))).await;
        assert_eq!(out["provider"], json!(expected));
    }
    let out = search(config(&overpass, Some(cfg.clone()))).await;

    assert_eq!(out["provider"], json!("openstreetmap"));
    assert_eq!(out["places"][0]["provider"], json!("openstreetmap"));
    let why = out["provider_fallback_reason"].as_str().expect("a reason");
    assert!(
        why.contains("2 of 2"),
        "the reason names the ceiling: {why}"
    );
    assert!(why.contains("3600"), "and the window: {why}");
    assert_eq!(
        out["budget"],
        json!({"used": 2, "limit": 2, "window_seconds": 3600})
    );

    assert_eq!(
        seen.lock().unwrap().bodies.len(),
        2,
        "the third call must not reach the paid source at all"
    );
    assert_eq!(osm_seen.lock().unwrap().bodies.len(), 1);

    // The ledger is the audit trail: two lines, one per billed call, readable as text.
    let ledger = std::fs::read_to_string(sc.ledger()).unwrap();
    assert_eq!(ledger.lines().count(), 2, "{ledger}");
    assert!(ledger.contains("places_search"));
}

// ---- the rest of the policy ---------------------------------------------------------------

/// A deployment can pin itself to the free source WITH a key present — which is what makes a
/// like-for-like comparison of the two possible from one deployment.
#[tokio::test]
async fn a_deployment_can_pin_itself_to_the_free_source() {
    let sc = Scratch::new("pinned");
    let (overpass, osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_body())).await;
    let mut cfg = config(&overpass, Some(google_cfg(&google, &sc, 10)));
    cfg.provider_preference = ProviderPreference::OpenStreetMapOnly;
    let out = search(cfg).await;

    assert_eq!(out["provider"], json!("openstreetmap"));
    let why = out["provider_fallback_reason"].as_str().expect("a reason");
    assert!(why.contains("JESSE_PLACES_PROVIDER"), "{why}");
    assert!(
        seen.lock().unwrap().bodies.is_empty(),
        "and nothing was spent"
    );
    assert_eq!(osm_seen.lock().unwrap().bodies.len(), 1);
    assert!(
        !sc.ledger().exists(),
        "a pinned deployment writes no ledger line"
    );
}

/// A category the paid source has no type for is served by the free source, which has the
/// tag — and the paid source is not asked a broader question it could bill for.
#[tokio::test]
async fn a_category_the_paid_source_cannot_express_goes_to_the_free_one() {
    let sc = Scratch::new("unsupported-category");
    let (overpass, _osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_body())).await;
    let client =
        PlacesClient::new(config(&overpass, Some(google_cfg(&google, &sc, 10)))).expect("client");
    let out = run_places_tool(
        &client,
        PlacesTool::Search,
        &json!({"query": "optician", "latitude": 55.9435, "longitude": -3.2081}),
    )
    .await
    .expect("search must answer");

    assert_eq!(out["provider"], json!("openstreetmap"));
    let why = out["provider_fallback_reason"].as_str().expect("a reason");
    assert!(why.contains("no place type for optician"), "{why}");
    assert!(
        seen.lock().unwrap().bodies.is_empty(),
        "nothing was spent on it"
    );
}

/// The two tools agree about the shape of a record. `place_details` on a paid-source id sends
/// the DETAILS field mask (no `places.` prefix — a prefixed one is a 400) and comes back in
/// the same shape search produced.
#[tokio::test]
async fn details_on_a_paid_source_id_uses_the_details_mask() {
    let sc = Scratch::new("paid-details");
    let (overpass, _osm) = start_fake_overpass().await;
    let one = google_body()["places"][0].clone();
    let (google, seen) = start_fake_google(Ok(one)).await;
    let client =
        PlacesClient::new(config(&overpass, Some(google_cfg(&google, &sc, 10)))).expect("client");
    let out = run_places_tool(
        &client,
        PlacesTool::Details,
        &json!({"id": "google/ChIJFixture", "timezone": "Europe/London"}),
    )
    .await
    .expect("details must answer");

    assert_eq!(out["provider"], json!("google_places"));
    assert_eq!(out["id"], json!("google/ChIJFixture"));
    assert_eq!(out["rating"], json!(4.4));
    assert_eq!(out["rating_count"], json!(2183));
    assert_eq!(out["opening_hours"]["parsed"], json!(true));
    assert_eq!(out["opening_hours"]["timezone"], json!("Europe/London"));
    assert!(
        out.get("distance_m").is_none(),
        "there is no search centre to be a distance from"
    );
    let s = seen.lock().unwrap();
    assert_eq!(s.paths, vec!["places/ChIJFixture".to_string()]);
    assert_eq!(s.masks, vec![GOOGLE_DETAILS_FIELD_MASK.to_string()]);
}

/// **An id names a source, so an unavailable source is an ERROR rather than an answer from
/// the other one.** Quietly resolving it against the free source would return a DIFFERENT
/// PLACE under the id the caller asked about.
#[tokio::test]
async fn details_on_a_paid_source_id_with_no_key_fails_rather_than_answering_wrongly() {
    let (overpass, osm_seen) = start_fake_overpass().await;
    let client = PlacesClient::new(config(&overpass, None)).expect("client");
    let err = run_places_tool(
        &client,
        PlacesTool::Details,
        &json!({"id": "google/ChIJFixture"}),
    )
    .await
    .expect_err("this must not answer from the other source");

    assert!(err.contains("no API key is configured"), "{err}");
    assert!(
        err.contains("places_search"),
        "it says what to do instead: {err}"
    );
    assert!(
        osm_seen.lock().unwrap().bodies.is_empty(),
        "and it did not go and look somewhere else"
    );
}

/// An id from the free source still resolves after the second one landed. Every id a caller
/// already holds keeps working.
#[tokio::test]
async fn details_on_a_free_source_id_still_resolves() {
    let sc = Scratch::new("free-details");
    let (overpass, osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_body())).await;
    let client =
        PlacesClient::new(config(&overpass, Some(google_cfg(&google, &sc, 10)))).expect("client");
    let out = run_places_tool(
        &client,
        PlacesTool::Details,
        &json!({"id": "node/1375266472", "timezone": "Europe/London"}),
    )
    .await
    .expect("details must answer");

    assert_eq!(out["provider"], json!("openstreetmap"));
    assert_eq!(out["id"], json!("node/1375266472"));
    assert!(out.get("rating").is_none());
    assert_eq!(out["opening_hours"]["parsed"], json!(true));
    assert!(out["all_tags"].is_object());
    assert_eq!(osm_seen.lock().unwrap().bodies.len(), 1);
    assert!(
        seen.lock().unwrap().paths.is_empty(),
        "an id from the free source costs nothing"
    );
}

/// **No response from the paid source is ever cached**, because its terms permit caching only
/// place ids and coordinates. Two identical searches are two billed calls, and the count says
/// so — the opposite of the free source, whose responses are cached for five minutes.
#[tokio::test]
async fn the_paid_sources_responses_are_never_reused() {
    let sc = Scratch::new("no-cache");
    let (overpass, _osm) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_body())).await;
    let cfg = config(&overpass, Some(google_cfg(&google, &sc, 10)));
    let client = PlacesClient::new(cfg).expect("client");

    for expected in 1..=3 {
        let out = run_places_tool(&client, PlacesTool::Search, &search_args())
            .await
            .expect("search");
        assert_eq!(out["provider"], json!("google_places"));
        assert_eq!(
            out["budget"]["used"],
            json!(expected),
            "every call is a fresh call"
        );
    }
    assert_eq!(seen.lock().unwrap().bodies.len(), 3);
}

// ---- the richer field set ------------------------------------------------------------------

/// One paid-source record at the richer level: everything the standard fixture has, plus the
/// two fields the dearer mask buys. The review is shaped exactly as a live response shapes
/// one, author attribution and source link included, because those two are what the tool has
/// to carry to be allowed to return the text at all.
fn google_rich_body() -> Value {
    let mut body = google_body();
    body["places"][0]["editorialSummary"] =
        json!({"text": "A long-established kiltmaker.", "languageCode": "en"});
    body["places"][0]["reviews"] = json!([{
        "name": "places/ChIJFixture/reviews/Ci9DQUlR",
        "relativePublishTimeDescription": "a month ago",
        "rating": 5,
        "text": {"text": "The fitting was unhurried and the staff were kind.", "languageCode": "en"},
        "originalText": {"text": "The fitting was unhurried and the staff were kind.", "languageCode": "en"},
        "authorAttribution": {
            "displayName": "A Reviewer",
            "uri": "https://www.google.com/maps/contrib/1/reviews",
            "photoUri": "https://lh3.googleusercontent.com/a/x=s128",
        },
        "publishTime": "2026-07-04T13:57:43.708815105Z",
        "flagContentUri": "https://www.google.com/local/content/rap/report?postId=x",
        "googleMapsUri": "https://www.google.com/maps/reviews/data=!4m6",
    }]);
    body
}

fn rich_search_args() -> Value {
    let mut a = search_args();
    a["detail"] = json!("rich");
    a
}

/// **The default did not move, asserted against the bytes that left the host.** A search with
/// no `detail` argument sends the mask 0.104.0 sent, and reports the standard tier — this is
/// the regression that matters most, because everything else here is opt-in.
#[tokio::test]
async fn a_search_with_no_detail_argument_sends_exactly_the_old_mask() {
    let sc = Scratch::new("detail-default");
    let (overpass, _osm) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_body())).await;
    let out = search(config(&overpass, Some(google_cfg(&google, &sc, 10)))).await;

    assert_eq!(seen.lock().unwrap().masks, vec![GOOGLE_SEARCH_FIELD_MASK]);
    assert_eq!(out["detail"], json!("standard"));
    assert_eq!(out["detail_requested"], json!("standard"));
    assert_eq!(out["cost_tier"], json!("enterprise"));
    assert_eq!(out["field_mask"], json!(GOOGLE_SEARCH_FIELD_MASK));
    assert!(
        out.get("detail_fallback_reason").is_none(),
        "nothing was downgraded"
    );
    // The record carries no review keys at all — not an empty array, which would read as
    // "this place has no reviews".
    for absent in ["reviews", "reviews_notice", "editorial_summary"] {
        assert!(out["places"][0].get(absent).is_none(), "{absent}");
    }
    // And the ledger line is the one the old code wrote.
    let ledger = std::fs::read_to_string(sc.ledger()).unwrap();
    assert!(ledger.contains("\tenterprise\t1/10"), "{ledger}");
    assert!(!ledger.contains("enterprise_atmosphere"), "{ledger}");
}

/// **`rich` sends the dearer mask and nothing dearer still** — and the egress property is
/// untouched: the request body is the same coordinate, radius, count and table-supplied
/// types, with no caller-authored string and no `textQuery`. The extra spend buys FIELDS in
/// the response, never a new channel out of the host.
#[tokio::test]
async fn a_rich_search_sends_the_rich_mask_and_still_no_caller_string() {
    let sc = Scratch::new("detail-rich");
    let (overpass, osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_rich_body())).await;
    let client =
        PlacesClient::new(config(&overpass, Some(google_cfg(&google, &sc, 10)))).expect("client");
    let out = run_places_tool(&client, PlacesTool::Search, &rich_search_args())
        .await
        .expect("search must answer");

    assert_eq!(out["provider"], json!("google_places"));
    assert_eq!(out["detail"], json!("rich"));
    assert_eq!(out["detail_requested"], json!("rich"));
    assert_eq!(out["cost_tier"], json!("enterprise_atmosphere"));
    assert_eq!(out["field_mask"], json!(GOOGLE_SEARCH_FIELD_MASK_RICH));

    let s = seen.lock().unwrap();
    assert_eq!(
        s.masks,
        vec![GOOGLE_SEARCH_FIELD_MASK_RICH.to_string()],
        "the mask on the wire is the rich one, exactly"
    );
    // THE EGRESS PROPERTY IS UNCHANGED BY THE RICHER FIELD SET.
    let body = &s.bodies[0];
    let sent: Value = serde_json::from_str(body).expect("a JSON body");
    assert_eq!(sent["includedTypes"], json!(["cafe", "coffee_shop"]));
    assert!(
        sent.get("textQuery").is_none(),
        "the free-text endpoint is still not used and its parameter is still never sent"
    );
    assert!(
        !body.contains("rich") && !body.contains("detail"),
        "the detail level is a mask header and a budget decision, not a request field: {body}"
    );
    drop(s);
    assert!(osm_seen.lock().unwrap().bodies.is_empty());

    // What the extra spend actually bought, on the record.
    let p = &out["places"][0];
    assert_eq!(
        p["editorial_summary"],
        json!("A long-established kiltmaker.")
    );
    assert_eq!(
        p["reviews"][0]["text"],
        json!("The fitting was unhurried and the staff were kind.")
    );
    // AND THE OBLIGATIONS THAT COME WITH IT: an author, and a link to the review at source.
    assert_eq!(p["reviews"][0]["author"]["name"], json!("A Reviewer"));
    assert!(p["reviews"][0]["author"]["profile_url"].is_string());
    assert!(p["reviews"][0]["author"]["avatar_url"].is_string());
    assert!(p["reviews"][0]["source_url"].is_string());
    assert!(
        p["reviews_notice"]
            .as_str()
            .expect("the ordering notice travels with the reviews")
            .contains("order the source returned them"),
        "{p}"
    );
    // The standard fields are all still there — `rich` adds, it does not replace.
    assert_eq!(p["rating"], json!(4.4));
    assert_eq!(p["rating_count"], json!(2183));
    assert_eq!(p["opening_hours"]["parsed"], json!(true));
}

/// **A rich call is accounted under its own key with its own ceiling, and the ordinary budget
/// object is untouched.** A shared undifferentiated counter would let a loop of dear calls
/// spend several times what the number in the response implies.
#[tokio::test]
async fn a_rich_call_is_accounted_separately_from_an_ordinary_one() {
    let sc = Scratch::new("detail-ledger");
    let (overpass, _osm) = start_fake_overpass().await;
    let (google, _seen) = start_fake_google(Ok(google_rich_body())).await;
    let client =
        PlacesClient::new(config(&overpass, Some(google_cfg(&google, &sc, 10)))).expect("client");

    let standard = run_places_tool(&client, PlacesTool::Search, &search_args())
        .await
        .expect("search");
    assert_eq!(
        standard["budget"],
        json!({"used": 1, "limit": 10, "window_seconds": 3600}),
        "the object 0.104.0 emitted, unchanged in keys and in values"
    );
    assert_eq!(
        standard["rich_budget"],
        json!({"used": 0, "limit": 10, "window_seconds": 3600}),
        "an ordinary call spends none of the rich allowance"
    );

    let rich = run_places_tool(&client, PlacesTool::Search, &rich_search_args())
        .await
        .expect("search");
    assert_eq!(
        rich["budget"],
        json!({"used": 2, "limit": 10, "window_seconds": 3600}),
        "a rich call is still a call and counts against the ordinary ceiling too"
    );
    assert_eq!(
        rich["rich_budget"],
        json!({"used": 1, "limit": 10, "window_seconds": 3600})
    );

    // The ledger tells them apart by tier, which is what the second ceiling reads back.
    let ledger = std::fs::read_to_string(sc.ledger()).unwrap();
    let lines: Vec<&str> = ledger.lines().collect();
    assert_eq!(lines.len(), 2, "{ledger}");
    assert!(lines[0].contains("\tenterprise\t"), "{ledger}");
    assert!(lines[1].contains("\tenterprise_atmosphere\t"), "{ledger}");
    assert!(lines[1].contains("rich=1/10"), "{ledger}");
}

/// **The rich ceiling trips on its own, with the ordinary budget barely touched** — and the
/// tool keeps answering, because a spent budget has always meant a fallback rather than a
/// failure. The reason names the ceiling that stopped it.
#[tokio::test]
async fn a_spent_rich_ceiling_falls_back_while_the_ordinary_budget_still_has_room() {
    let sc = Scratch::new("detail-rich-cap");
    let (overpass, osm_seen) = start_fake_overpass().await;
    let (google, seen) = start_fake_google(Ok(google_rich_body())).await;
    let mut cfg = google_cfg(&google, &sc, 20);
    cfg.rich_max_calls = 1;
    let client = PlacesClient::new(config(&overpass, Some(cfg))).expect("client");

    let first = run_places_tool(&client, PlacesTool::Search, &rich_search_args())
        .await
        .expect("search");
    assert_eq!(first["provider"], json!("google_places"));
    assert_eq!(first["detail"], json!("rich"));

    let second = run_places_tool(&client, PlacesTool::Search, &rich_search_args())
        .await
        .expect("search must still answer");
    assert_eq!(
        second["provider"],
        json!("openstreetmap"),
        "a spent budget falls back rather than failing"
    );
    let why = second["provider_fallback_reason"]
        .as_str()
        .expect("a reason");
    assert!(
        why.contains("richer field set") && why.contains("1 of 1"),
        "the reason names the ceiling that stopped it: {why}"
    );
    assert!(
        why.contains("1 of 20"),
        "and says the ordinary budget still has room: {why}"
    );
    assert_eq!(second["detail"], json!("standard"));
    assert_eq!(second["detail_requested"], json!("rich"));
    assert_eq!(
        seen.lock().unwrap().bodies.len(),
        1,
        "the second call must not reach the paid source at all"
    );
    assert_eq!(osm_seen.lock().unwrap().bodies.len(), 1);

    // AND THE CHEAP ANSWER IS STILL AVAILABLE FROM THE PAID SOURCE. The rich budget is spent;
    // the ordinary one is not, so a standard call still gets ratings and hours.
    let standard = run_places_tool(&client, PlacesTool::Search, &search_args())
        .await
        .expect("search");
    assert_eq!(standard["provider"], json!("google_places"));
    assert_eq!(standard["detail"], json!("standard"));
}

/// **A rich request the free source serves says so, in the same voice a provider fallback
/// uses** — rather than silently returning a standard record that a caller would read as
/// "this place has no reviews".
#[tokio::test]
async fn a_rich_request_served_by_the_free_source_announces_it() {
    let (overpass, _osm) = start_fake_overpass().await;
    let client = PlacesClient::new(config(&overpass, None)).expect("client");
    let out = run_places_tool(&client, PlacesTool::Search, &rich_search_args())
        .await
        .expect("search must answer");

    assert_eq!(out["provider"], json!("openstreetmap"));
    assert_eq!(out["detail_requested"], json!("rich"), "what was asked for");
    assert_eq!(out["detail"], json!("standard"), "what was served");
    let why = out["detail_fallback_reason"]
        .as_str()
        .expect("a rich request the free source served must explain itself");
    assert!(why.contains("no review text"), "{why}");
    assert!(
        !why.is_empty() && why.contains("bills per request"),
        "it says where a richer answer would have to come from: {why}"
    );
    assert!(
        out.get("cost_tier").is_none() && out.get("field_mask").is_none(),
        "nothing was billed, so no price and no mask are reported"
    );
    // A real answer still came back — the downgrade is announced, not fatal.
    assert_eq!(out["returned"], json!(1));
}

/// **The empty answer explains itself, at no cost.** A bare business name matches no category,
/// so nothing narrows what is fetched and the name only sieves what came back — which is the
/// whole reason this returns nothing, and is knowable before any source is asked.
#[tokio::test]
async fn a_bare_business_name_that_finds_nothing_says_why() {
    let (overpass, _osm) = start_fake_overpass().await;
    let client = PlacesClient::new(config(&overpass, None)).expect("client");
    let out = run_places_tool(
        &client,
        PlacesTool::Search,
        &json!({"query": "Anderson Kilts", "latitude": 55.0701, "longitude": -3.6053, "radius_m": 1500}),
    )
    .await
    .expect("search must answer");

    assert_eq!(out["returned"], json!(0));
    assert_eq!(out["used_fallback_categories"], json!(true));
    assert_eq!(out["matched_categories"], json!([]));
    let why = out["no_results_explanation"]
        .as_str()
        .expect("an empty result from a category-less query must explain itself");
    assert!(why.contains("category word"), "{why}");
    assert!(why.contains("bare business name"), "{why}");

    // AND IT DOES NOT FIRE WHEN A CATEGORY MATCHED. There an empty result is a real answer —
    // no café within the radius — and explaining it would be noise.
    let out = run_places_tool(
        &client,
        PlacesTool::Search,
        &json!({"query": "bakery Nowhere", "latitude": 55.0701, "longitude": -3.6053}),
    )
    .await
    .expect("search must answer");
    assert_eq!(out["used_fallback_categories"], json!(false));
    assert!(
        out.get("no_results_explanation").is_none(),
        "a category matched, so an empty result needs no explaining"
    );
}

/// **`place_details` at the standard level on a paid-source id buys nothing, and now says
/// so.** The details mask names the same field set the search mask does, so the call spends a
/// billed request to return values the caller already had.
#[tokio::test]
async fn standard_details_on_a_paid_id_says_it_added_nothing() {
    let sc = Scratch::new("detail-details-standard");
    let (overpass, _osm) = start_fake_overpass().await;
    let one = google_body()["places"][0].clone();
    let (google, seen) = start_fake_google(Ok(one)).await;
    let client =
        PlacesClient::new(config(&overpass, Some(google_cfg(&google, &sc, 10)))).expect("client");
    let out = run_places_tool(
        &client,
        PlacesTool::Details,
        &json!({"id": "google/ChIJFixture", "timezone": "Europe/London"}),
    )
    .await
    .expect("details must answer");

    assert_eq!(out["detail"], json!("standard"));
    assert_eq!(seen.lock().unwrap().masks, vec![GOOGLE_DETAILS_FIELD_MASK]);
    let said = out["detail_adds_nothing_here"]
        .as_str()
        .expect("a call that spends money for no new information must say so");
    assert!(said.contains("added no information"), "{said}");
    assert!(
        said.contains("rich"),
        "and names the level that would have added some: {said}"
    );
    // The two masks really do name the same fields — the claim above, checked rather than
    // asserted in prose.
    let mut search_fields: Vec<&str> = GOOGLE_SEARCH_FIELD_MASK
        .split(',')
        .map(|f| f.trim_start_matches("places."))
        .collect();
    let mut details_fields: Vec<&str> = GOOGLE_DETAILS_FIELD_MASK.split(',').collect();
    search_fields.sort_unstable();
    details_fields.sort_unstable();
    assert_eq!(
        search_fields, details_fields,
        "if these ever differ, the sentence above becomes a lie and must change with them"
    );
}

/// **`rich` is what gives `place_details` a reason to exist on the paid source**: review text
/// for one place, without re-running — and re-paying for — the whole search at the dearer mask.
#[tokio::test]
async fn rich_details_uses_the_rich_details_mask_and_returns_the_reviews() {
    let sc = Scratch::new("detail-details-rich");
    let (overpass, _osm) = start_fake_overpass().await;
    let one = google_rich_body()["places"][0].clone();
    let (google, seen) = start_fake_google(Ok(one)).await;
    let client =
        PlacesClient::new(config(&overpass, Some(google_cfg(&google, &sc, 10)))).expect("client");
    let out = run_places_tool(
        &client,
        PlacesTool::Details,
        &json!({"id": "google/ChIJFixture", "detail": "rich", "timezone": "Europe/London"}),
    )
    .await
    .expect("details must answer");

    let s = seen.lock().unwrap();
    assert_eq!(
        s.masks,
        vec![GOOGLE_DETAILS_FIELD_MASK_RICH.to_string()],
        "unprefixed, and the rich one"
    );
    assert!(
        !GOOGLE_DETAILS_FIELD_MASK_RICH.contains("places."),
        "a prefixed details mask is a 400 from the provider"
    );
    drop(s);

    assert_eq!(out["detail"], json!("rich"));
    assert_eq!(out["cost_tier"], json!("enterprise_atmosphere"));
    assert_eq!(out["field_mask"], json!(GOOGLE_DETAILS_FIELD_MASK_RICH));
    assert!(
        out.get("detail_adds_nothing_here").is_none(),
        "this call added something, so it must not claim otherwise"
    );
    assert_eq!(
        out["reviews"][0]["text"],
        json!("The fitting was unhurried and the staff were kind.")
    );
    assert_eq!(out["reviews"][0]["author"]["name"], json!("A Reviewer"));
    assert!(out["reviews"][0]["source_url"].is_string());
    assert!(out["reviews_notice"].is_string());
    assert_eq!(out["rich_budget"]["used"], json!(1));
}

/// A rich request against an id from the FREE source is announced rather than answered as
/// though it had been served — that source has no such fields at any price.
#[tokio::test]
async fn rich_details_on_a_free_source_id_announces_the_downgrade() {
    let (overpass, _osm) = start_fake_overpass().await;
    let client = PlacesClient::new(config(&overpass, None)).expect("client");
    let out = run_places_tool(
        &client,
        PlacesTool::Details,
        &json!({"id": "node/1375266472", "detail": "rich"}),
    )
    .await
    .expect("details must answer");

    assert_eq!(out["provider"], json!("openstreetmap"));
    assert_eq!(out["detail_requested"], json!("rich"));
    assert_eq!(out["detail"], json!("standard"));
    assert!(out["detail_fallback_reason"]
        .as_str()
        .expect("announced")
        .contains("no review text"));
    assert!(out.get("reviews").is_none());
}

/// An unrecognised `detail` value is refused on both tools rather than answered cheaply — a
/// caller that believes it asked for reviews must not be handed a standard record silently.
#[tokio::test]
async fn an_unrecognised_detail_level_is_refused_on_both_tools() {
    let (overpass, osm_seen) = start_fake_overpass().await;
    let client = PlacesClient::new(config(&overpass, None)).expect("client");

    let mut args = search_args();
    args["detail"] = json!("everything");
    let err = run_places_tool(&client, PlacesTool::Search, &args)
        .await
        .expect_err("an unknown detail level must not be answered");
    assert!(err.contains("standard") && err.contains("rich"), "{err}");

    let err = run_places_tool(
        &client,
        PlacesTool::Details,
        &json!({"id": "node/1", "detail": "everything"}),
    )
    .await
    .expect_err("nor on the other tool");
    assert!(err.contains("standard") && err.contains("rich"), "{err}");
    assert!(
        osm_seen.lock().unwrap().bodies.is_empty(),
        "and neither one went and looked anything up first"
    );
}
