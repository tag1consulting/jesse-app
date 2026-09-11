//! The HTTP boundary of recorded-audio transcription — and the ONLY file under `speech/` that
//! may see the application state. `scripts/ci-guards.sh` holds every other file here to that.
//!
//! * `POST /jesse/transcriptions` — THE ONE DOOR. The body is the recording itself, streamed to
//!   disk through the intake gate; `Content-Type` declares its type and is checked against the
//!   magic bytes; `?language=`, `?conditioning=` and `?second_reading=` tune the run. Answers
//!   `202` with the run's first status.
//! * `GET /jesse/transcriptions/{id}` — the run's status, then its transcript and
//!   disagreement list. Polled by the app; not rate-limited, because a poll is not work.
//! * `POST /jesse/transcriptions/{id}/cancel` — stop the run; its audio is deleted.
//! * `GET /jesse/speech` — whether this bridge transcribes, and with which models.
//!
//! Same bearer auth as every other route. The upload route carries its OWN body limit (the
//! audio cap, enforced while streaming) instead of the router's, which is sized for base64
//! photos and would refuse a recording long before its cap.

use super::intake::{over_cap, AudioCustody, SniffedUpload, UploadGate};
use super::service::JobOptions;
use crate::*;
use tokio::io::AsyncWriteExt;

/// The tuning a recording may carry.
#[derive(Deserialize, Default)]
pub struct TranscribeQuery {
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub conditioning: Option<String>,
    #[serde(default)]
    pub second_reading: Option<String>,
}

pub async fn jesse_transcribe(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<TranscribeQuery>,
    body: axum::body::Body,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let speech = st.speech.clone();
    speech
        .availability()
        .map_err(|e| (StatusCode::SERVICE_UNAVAILABLE, e))?;
    let opts = JobOptions::parse(
        q.language.as_deref(),
        q.conditioning.as_deref(),
        q.second_reading.as_deref(),
    )
    .map_err(|e| (StatusCode::BAD_REQUEST, e))?;
    let declared = headers
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            (
                StatusCode::BAD_REQUEST,
                "declare the recording's type in Content-Type, for example audio/mp4".to_string(),
            )
        })?;
    let cap = speech.config.max_audio_bytes;
    // Refuse a declared over-cap body before a byte of it is read. A body with no length (or
    // one that lies) is held to the same cap by the gate as it streams.
    if let Some(len) = headers
        .get(axum::http::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())
    {
        if len > cap {
            return Err(over_cap(cap));
        }
    }
    let root = speech.intake_dir().ok_or_else(|| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "this bridge has no intake directory".to_string(),
        )
    })?;
    let custody = AudioCustody::open(&root).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not open a private intake directory: {e}"),
        )
    })?;
    // From here every early return drops `custody`, which deletes whatever arrived.
    let partial = custody.file("upload.part");
    let sniffed = receive(body, &partial, UploadGate::new(&declared, cap)).await?;
    let upload = custody.file(&format!("upload.{}", sniffed.ext));
    std::fs::rename(&partial, &upload).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not keep the upload: {e}"),
        )
    })?;
    let status = speech.start(custody, upload, sniffed, opts);
    Ok((StatusCode::ACCEPTED, Json(status)).into_response())
}

/// Stream the body to `dest` (0600) through the gate. Memory is bounded by one chunk.
async fn receive(
    body: axum::body::Body,
    dest: &Path,
    mut gate: UploadGate,
) -> Result<SniffedUpload, ApiError> {
    let internal = |what: &str, e: std::io::Error| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("could not {what} the upload: {e}"),
        )
    };
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(dest)
        .await
        .map_err(|e| internal("store", e))?;
    let mut stream = Box::pin(body.into_data_stream());
    while let Some(chunk) = std::future::poll_fn(|cx| stream.as_mut().poll_next(cx)).await {
        let chunk = chunk.map_err(|e| {
            (
                StatusCode::BAD_REQUEST,
                format!("the upload was interrupted: {e}"),
            )
        })?;
        gate.accept(&chunk)?;
        file.write_all(&chunk)
            .await
            .map_err(|e| internal("write", e))?;
    }
    file.sync_all().await.map_err(|e| internal("flush", e))?;
    gate.finish()
}

fn not_found() -> ApiError {
    (
        StatusCode::NOT_FOUND,
        "no such transcription — a finished one is kept for an hour, and none survives a \
         bridge restart"
            .to_string(),
    )
}

pub async fn jesse_transcription(
    State(st): State<AppState>,
    headers: HeaderMap,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    st.speech.status(&id).map(Json).ok_or_else(not_found)
}

pub async fn jesse_transcription_cancel(
    State(st): State<AppState>,
    headers: HeaderMap,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    st.speech.cancel(&id).map(Json).ok_or_else(not_found)
}

pub async fn jesse_speech(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    Ok(Json(st.speech.overview()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::speech::decode::SystemDecoder;
    use crate::speech::engine::fakes::{ScriptedEngine, ScriptedLoader};
    use crate::speech::engine::{EngineError, Segment};
    use crate::speech::models::fakes::{entry, FakeFetcher};
    use crate::speech::models::SpeechTier;
    use crate::speech::service::{SpeechConfig, SpeechService};
    use crate::speech::wav::encode_wav16;
    use crate::testutil::*;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    struct Rig {
        st: AppState,
        root: PathBuf,
        fetcher: Arc<FakeFetcher>,
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn engine(id: &str, lines: &[(u64, u64, &str)]) -> ScriptedEngine {
        ScriptedEngine::new(
            id,
            lines
                .iter()
                .map(|(a, b, t)| Segment::new(a * 1_000, b * 1_000, t))
                .collect(),
        )
    }

    fn rig_with(mut cfg: Config, primary: ScriptedEngine, second: ScriptedEngine) -> Rig {
        let root = std::env::temp_dir().join(format!("jesse-speech-http-{}", random_hex()));
        cfg.speech = SpeechConfig::at(&root);
        let p = entry(
            "primary-model",
            SpeechTier::Accurate,
            10,
            b"primary weights",
        );
        let s = entry("second-model", SpeechTier::Fast, 10, b"second weights");
        let fetcher = Arc::new(FakeFetcher::serving(&[
            (&p, b"primary weights"),
            (&s, b"second weights"),
        ]));
        let loader = Arc::new(ScriptedLoader::with(vec![primary, second]));
        let mut st = AppState::new(cfg);
        st.speech = Arc::new(SpeechService::with_parts(
            st.cfg.speech.clone(),
            vec![p, s],
            fetcher.clone(),
            loader,
            // No system decoder: a 16 kHz WAV is read directly, so the pipeline runs anywhere.
            Arc::new(SystemDecoder::with_tool(root.join("no-afconvert"))),
        ));
        Rig { st, root, fetcher }
    }

    fn rig(primary: ScriptedEngine, second: ScriptedEngine) -> Rig {
        rig_with(test_config(), primary, second)
    }

    /// A 16 kHz WAV of a quiet-ish tone: enough samples to exercise the whole pipeline.
    fn recording(seconds: f32) -> Vec<u8> {
        let n = (16_000.0 * seconds) as usize;
        let samples: Vec<f32> = (0..n)
            .map(|i| 0.3 * (2.0 * std::f32::consts::PI * 300.0 * i as f32 / 16_000.0).sin())
            .collect();
        encode_wav16(&samples, 16_000)
    }

    fn upload(body: Vec<u8>, content_type: Option<&str>, query: &str) -> Request<Body> {
        let mut b = Request::post(format!("/jesse/transcriptions{query}"))
            .header("authorization", "Bearer test-token");
        if let Some(ct) = content_type {
            b = b.header("content-type", ct);
        }
        b.body(Body::from(body)).unwrap()
    }

    fn get(path: &str) -> Request<Body> {
        Request::get(path)
            .header("authorization", "Bearer test-token")
            .body(Body::empty())
            .unwrap()
    }

    async fn body_json(resp: Response) -> Value {
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    }

    async fn settle(app: &Router, id: &str) -> Value {
        for _ in 0..1_000 {
            let v = body_json(
                app.clone()
                    .oneshot(get(&format!("/jesse/transcriptions/{id}")))
                    .await
                    .unwrap(),
            )
            .await;
            if v["state"] != "running" {
                return v;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("run {id} never finished");
    }

    async fn start(app: &Router, body: Vec<u8>, query: &str) -> String {
        let resp = app
            .clone()
            .oneshot(upload(body, Some("audio/wav"), query))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::ACCEPTED);
        let v = body_json(resp).await;
        v["id"].as_str().expect("an id").to_string()
    }

    fn intake_is_empty(root: &Path) -> bool {
        std::fs::read_dir(root.join("speech-intake"))
            .map(|d| d.count() == 0)
            .unwrap_or(true)
    }

    #[tokio::test]
    async fn a_recording_is_transcribed_on_the_studio_and_its_audio_is_gone_afterwards() {
        let r = rig(
            engine(
                "primary-model",
                &[
                    (0, 6, "The collection will be picked up"),
                    (6, 11, "on Thursday the 14th."),
                ],
            ),
            engine(
                "second-model",
                &[(
                    0,
                    11,
                    "The collection will be picked up on Thursday the 15th.",
                )],
            ),
        );
        let app = app(r.st.clone());
        let id = start(&app, recording(2.0), "?language=it-IT").await;
        let v = settle(&app, &id).await;
        assert_eq!(v["state"], "done", "{v}");
        assert_eq!(
            v["transcript"],
            "The collection will be picked up on Thursday the 14th."
        );
        assert_eq!(v["language"], "it");
        assert_eq!(v["disagreements"][0]["primary"], "14th.");
        assert_eq!(v["disagreements"][0]["alternative"], "15th.");
        assert_eq!(v["engines"][0]["role"], "primary");
        assert_eq!(v["engines"][1]["role"], "second");
        assert!(v["conditioning"]["applied"].is_boolean());
        assert_eq!(v["duration_secs"], 2.0);
        assert!(
            intake_is_empty(&r.root),
            "the audio is deleted when the run ends"
        );
        let mut fetched = r.fetcher.fetched.lock_ok().clone();
        fetched.sort();
        assert_eq!(
            fetched,
            vec!["primary-model", "second-model"],
            "installed on first need"
        );
    }

    #[tokio::test]
    async fn refused_uploads_leave_nothing_behind() {
        let mut cfg = test_config();
        cfg.rate_per_min = 1_000;
        let r = rig_with(
            cfg,
            engine("primary-model", &[]),
            engine("second-model", &[]),
        );
        let app = app(r.st.clone());
        let m4a = b"\x00\x00\x00\x1cftypM4A \x00\x00\x00\x00M4A mp42isom".to_vec();
        let png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
        for (body, ct, want) in [
            (m4a.clone(), Some("audio/wav"), StatusCode::BAD_REQUEST),
            (png, Some("image/png"), StatusCode::BAD_REQUEST),
            (m4a, None, StatusCode::BAD_REQUEST),
            (Vec::new(), Some("audio/wav"), StatusCode::BAD_REQUEST),
        ] {
            let resp = app.clone().oneshot(upload(body, ct, "")).await.unwrap();
            assert_eq!(resp.status(), want);
        }
        let resp = app
            .clone()
            .oneshot(upload(
                recording(0.1),
                Some("audio/wav"),
                "?conditioning=maybe",
            ))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
        assert!(
            intake_is_empty(&r.root),
            "a refused upload leaves no bytes on disk"
        );
    }

    #[tokio::test]
    async fn the_audio_cap_is_enforced_while_streaming() {
        let r = rig(engine("primary-model", &[]), engine("second-model", &[]));
        let mut speech = r.st.speech.config.clone();
        speech.max_audio_bytes = 1_000;
        let mut st = r.st.clone();
        st.speech = Arc::new(SpeechService::with_parts(
            speech,
            Vec::new(),
            Arc::new(FakeFetcher::default()),
            Arc::new(ScriptedLoader::default()),
            Arc::new(SystemDecoder::default()),
        ));
        let resp = app(st)
            .oneshot(upload(recording(1.0), Some("audio/wav"), ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert!(intake_is_empty(&r.root));
    }

    /// The router's body limit is sized for base64 photos. A recording far past it is still
    /// taken, because the upload route carries the audio cap instead.
    #[tokio::test]
    async fn a_recording_bigger_than_any_turn_body_is_accepted() {
        let mut cfg = test_config();
        cfg.max_attachments_total_bytes = 64 * 1024;
        let limit = attachment_body_limit(&cfg);
        let r = rig_with(
            cfg,
            engine("primary-model", &[(0, 1, "hello")]),
            engine("second-model", &[(0, 1, "hello")]),
        );
        let big = recording(40.0);
        assert!(big.len() > limit * 3, "{} vs {limit}", big.len());
        let app = app(r.st.clone());
        let id = start(&app, big, "?conditioning=off&second_reading=off").await;
        assert_eq!(settle(&app, &id).await["state"], "done");
    }

    #[tokio::test]
    async fn the_door_is_shut_without_a_token_and_when_speech_is_off() {
        let r = rig(engine("primary-model", &[]), engine("second-model", &[]));
        let unauthenticated = Request::post("/jesse/transcriptions")
            .header("content-type", "audio/wav")
            .body(Body::from(recording(0.1)))
            .unwrap();
        let resp = app(r.st.clone()).oneshot(unauthenticated).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        let mut st = r.st.clone();
        st.speech = Arc::new(SpeechService::from_config(SpeechConfig::disabled()));
        let resp = app(st)
            .oneshot(upload(recording(0.1), Some("audio/wav"), ""))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert!(body_text(resp).await.contains("JESSE_SPEECH"));
    }

    async fn body_text(resp: Response) -> String {
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    #[tokio::test]
    async fn a_cancelled_run_deletes_its_audio() {
        let mut holding = engine("primary-model", &[(0, 1, "never")]);
        holding.hold_until_cancelled = true;
        let r = rig(holding, engine("second-model", &[]));
        let app = app(r.st.clone());
        let id = start(&app, recording(0.5), "?conditioning=off").await;
        for _ in 0..500 {
            let v = body_json(
                app.clone()
                    .oneshot(get(&format!("/jesse/transcriptions/{id}")))
                    .await
                    .unwrap(),
            )
            .await;
            if v["phase"] == "transcribing" {
                assert_eq!(
                    v["engine"], "Scripted primary-model",
                    "the phase names the engine"
                );
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(
            !intake_is_empty(&r.root),
            "the audio is in custody while it is read"
        );
        let resp = app
            .clone()
            .oneshot(
                Request::post(format!("/jesse/transcriptions/{id}/cancel"))
                    .header("authorization", "Bearer test-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let v = settle(&app, &id).await;
        assert_eq!(v["state"], "cancelled");
        assert!(
            intake_is_empty(&r.root),
            "a cancel deletes the audio like any other ending"
        );
    }

    #[tokio::test]
    async fn every_failure_ends_with_its_kind_and_no_audio() {
        // No decoder for a 44.1 kHz file on a host with no system decoder.
        let r = rig(
            engine("primary-model", &[(0, 1, "x")]),
            engine("second-model", &[]),
        );
        let app1 = app(r.st.clone());
        let id = start(&app1, encode_wav16(&[0.1; 4_410], 44_100), "").await;
        let v = settle(&app1, &id).await;
        assert_eq!(v["state"], "failed");
        assert_eq!(v["error"]["kind"], "no_decoder");
        assert!(intake_is_empty(&r.root));

        // Music the engine decorated is no speech at all.
        let r = rig(
            engine("primary-model", &[(0, 8, "[Music]"), (8, 9, "♪ ♪")]),
            engine("second-model", &[]),
        );
        let app2 = app(r.st.clone());
        let id = start(&app2, recording(0.5), "").await;
        let v = settle(&app2, &id).await;
        assert_eq!(v["error"]["kind"], "no_speech");
        assert!(intake_is_empty(&r.root));

        // An engine that does not know the language says so.
        let mut unknown = engine("primary-model", &[]);
        unknown.fail = Some(EngineError::UnknownLanguage("xx".into()));
        let r = rig(unknown, engine("second-model", &[]));
        let app3 = app(r.st.clone());
        let id = start(&app3, recording(0.5), "?language=xx").await;
        assert_eq!(
            settle(&app3, &id).await["error"]["kind"],
            "unknown_language"
        );
    }

    #[tokio::test]
    async fn a_failed_second_reading_still_delivers_the_first_and_says_so() {
        let mut broken = engine("second-model", &[]);
        broken.fail = Some(EngineError::Failed("out of memory".into()));
        let r = rig(
            engine("primary-model", &[(0, 2, "Buonasera a tutti.")]),
            broken,
        );
        let app = app(r.st.clone());
        let id = start(&app, recording(0.5), "").await;
        let v = settle(&app, &id).await;
        assert_eq!(v["state"], "done");
        assert_eq!(v["transcript"], "Buonasera a tutti.");
        assert_eq!(v["engines"].as_array().unwrap().len(), 1);
        let notes = v["notes"].to_string();
        assert!(notes.contains("second reading failed"), "{notes}");
        assert!(notes.contains("cross-checked"), "{notes}");
    }

    #[tokio::test]
    async fn unknown_runs_are_404_and_the_overview_names_the_models() {
        let r = rig(engine("primary-model", &[]), engine("second-model", &[]));
        let app = app(r.st.clone());
        let resp = app
            .clone()
            .oneshot(get("/jesse/transcriptions/tr-nope"))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
        let v = body_json(app.oneshot(get("/jesse/speech")).await.unwrap()).await;
        assert_eq!(v["available"], true);
        assert_eq!(v["tier"], "accurate");
        let roles: Vec<&str> = v["models"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|m| m["role"].as_str())
            .collect();
        assert_eq!(roles, vec!["primary", "second"]);
    }

    // ---- THE EGRESS BAN ---------------------------------------------------------------

    /// A server that stands in for every hosted surface and counts every connection made to
    /// it. It answers nothing useful; the only thing that matters is whether anyone called.
    async fn hosted_backend() -> (String, Arc<AtomicU64>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let calls = Arc::new(AtomicU64::new(0));
        let c = calls.clone();
        tokio::spawn(async move {
            while let Ok((sock, _)) = listener.accept().await {
                c.fetch_add(1, Ordering::SeqCst);
                drop(sock);
            }
        });
        (url, calls)
    }

    fn backend_model(id: &str, url: &str) -> RegistryModel {
        RegistryModel {
            family: None,
            effort: None,
            login_model: None,
            version: None,
            aliases: Vec::new(),
            codex: Default::default(),
            id: id.to_string(),
            label: id.to_string(),
            kind: ModelKind::Hosted,
            wire: Wire::default_for_kind(ModelKind::Hosted),
            backend: Some((url.to_string(), "tok".to_string(), format!("{id}-v1"))),
            subagent_model: None,
            configured: true,
            level: Capability::Read,
            harness: CLAUDE_CODE_ID.to_string(),
            auth_scheme: None,
            quirks: DirectQuirks::default(),
            thinking: None,
            price: PriceDeck::ZERO,
            health: HealthConfig::default(),
            vision: Vec::new(),
            vision_complementary: false,
        }
    }

    const CANARY: &[u8] = b"JESSE-AUDIO-EGRESS-CANARY";

    /// THE AUDIO EGRESS BAN, on the wire.
    ///
    /// The active model AND the vision helper paired with it both point at a server that
    /// counts connections — every hosted surface a turn can reach from this process. A
    /// recording carrying a canary is then pushed through BOTH doors:
    ///
    /// 1. the transcription door, where it must be transcribed by the local engines and
    ///    nowhere else;
    /// 2. the turn door, as an attachment to the hosted model — the route by which audio
    ///    would reach a vision helper or a hosted child — where it must be refused before a
    ///    single byte is sent.
    ///
    /// The server must see NO connection at all. This fails loudly if a later change routes
    /// audio through the assistant, a vision helper, or any registered model — the property
    /// the retired `AudioIsNeverAnAttachmentTests` guarded, moved from "no audio on any wire"
    /// to "no audio on any wire that leaves the Studio".
    #[tokio::test]
    async fn recorded_audio_never_reaches_a_hosted_backend() {
        let (url, calls) = hosted_backend().await;
        let mut cfg = test_config();
        let mut hosted = backend_model("hosted", &url);
        hosted.vision = vec![VisionPartner {
            id: "helper".to_string(),
            role: VisionRole::Any,
        }];
        let mut models = cfg.model_registry.models.clone();
        models.push(hosted);
        models.push(backend_model("helper", &url));
        cfg.model_registry = ModelRegistry { models };
        let r = rig_with(
            cfg,
            engine("primary-model", &[(0, 2, "Pickup is on Thursday.")]),
            engine("second-model", &[(0, 2, "Pickup is on Thursday.")]),
        );
        r.st.models.set_active("hosted");
        assert!(
            !vision::resolve_partners(&r.st.cfg, &r.st.resolve_active_model().vision).is_empty(),
            "the rig must really route a turn's attachments to the recording helper"
        );
        let app = app(r.st.clone());

        let mut bytes = recording(1.0);
        for _ in 0..8 {
            bytes.extend_from_slice(CANARY);
        }
        // 1. The transcription door.
        let id = start(&app, bytes.clone(), "?conditioning=on").await;
        let v = settle(&app, &id).await;
        assert_eq!(v["state"], "done", "{v}");
        assert!(
            !v.to_string().contains("CANARY"),
            "the status never carries audio"
        );
        assert!(!v.to_string().contains(&base64_encode(CANARY)[..16]));

        // 2. The turn door: the same recording as an attachment to the hosted model.
        let turn = json!({
            "mode": "ask",
            "text": "What is in this recording?",
            "conversation_id": uuid::Uuid::new_v4().to_string(),
            "request_id": "egress-test",
            "attachments": [{
                "filename": "memo.wav",
                "mime": "audio/wav",
                "data_base64": base64_encode(&bytes),
            }],
        });
        let resp = app
            .clone()
            .oneshot(
                Request::post("/jesse")
                    .header("authorization", "Bearer test-token")
                    .header("content-type", "application/json")
                    .body(Body::from(turn.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_ne!(
            resp.status(),
            StatusCode::ACCEPTED,
            "audio must not start a turn"
        );
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
        assert!(body_text(resp).await.contains("unsupported"));

        // Anything that was going to reach the network has had time to.
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(
            calls.load(Ordering::SeqCst),
            0,
            "a hosted backend was contacted while recorded audio was in the bridge"
        );
        assert!(intake_is_empty(&r.root));
    }

    /// The same boundary one layer down: the turn attachment gate refuses every audio
    /// container the transcription door accepts, whatever MIME it is declared as.
    #[test]
    fn the_turn_attachment_gate_refuses_every_recording_format() {
        let cfg = test_config();
        let m4a = b"\x00\x00\x00\x1cftypM4A \x00\x00\x00\x00M4A mp42isom".to_vec();
        for (bytes, mime) in [
            (m4a.clone(), "audio/mp4"),
            (m4a, "image/heic"),
            (recording(0.1), "audio/wav"),
            (b"ID3\x04\x00\x00\x00\x00\x00".to_vec(), "audio/mpeg"),
        ] {
            let att = Attachment {
                filename: "memo".into(),
                mime: mime.into(),
                data_base64: base64_encode(&bytes),
            };
            let err = validate_and_decode_attachments(&cfg, &[att]).unwrap_err();
            assert_eq!(err.0, StatusCode::BAD_REQUEST, "{mime}");
        }
    }
}
