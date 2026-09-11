//! Recorded audio, transcribed ON THE STUDIO, by engines that run inside this process.
//!
//! # THE INVARIANT, first, because everything below is downstream of it
//!
//! **Recorded audio may reach this bridge and nothing past it.** It arrives over the tailnet
//! from the phone, or over loopback from the Mac app running on this machine, and from the
//! moment it lands it never leaves the Studio: not to the cloud assistant, not to a hosted
//! vision helper, not to any registered model, not to a hosted speech API. It is turned into
//! text here, by open models loaded from this disk into this process, and the audio is then
//! deleted. **Once it is text, nothing further is restricted** — the transcript is an
//! ordinary message and flows exactly as typed text does.
//!
//! This REPLACES an older rule, deliberately. App 1.0 (124) shipped "audio never goes on the
//! network": recordings were transcribed on whichever device held them, and a test in the app
//! (`AudioIsNeverAnAttachmentTests`) pinned it. That drew the line at the network interface,
//! which forbade the one thing this needs — reaching the strongest machine in the system —
//! while protecting nothing the new rule does not. The boundary was always the DESTINATION.
//! The replacement is stronger in the only direction that matters: it names every surface
//! audio must not reach and holds each one shut in code, where the old rule held one client
//! list.
//!
//! # How the code holds it
//!
//! 1. **ONE DOOR.** Audio is accepted on exactly one route, `POST /jesse/transcriptions`
//!    ([`http`]), and lands in an [`intake::AudioCustody`]. The turn ATTACHMENT gate
//!    (`crate::sniff_attachment`) still refuses every audio container, and must: a turn
//!    attachment can be routed to a hosted vision helper or read by a hosted child. A test
//!    pins that the two sniffers never accept the same bytes.
//! 2. **ONE KIND OF ENGINE.** An engine exists only as a model file on this disk loaded into
//!    this process ([`engine::EngineLoader`]). No configuration key names an engine by
//!    address; the known-good list ([`models::known_good`]) is the only source of engines.
//! 3. **NO HANDLE ON ANYTHING ELSE.** The pipeline ([`service`]) is handed its own parts and
//!    nothing more — no application state, no configuration, no model registry, no vision
//!    layer. `scripts/ci-guards.sh` fails the build if any file here other than the HTTP
//!    boundary names one.
//! 4. **THE ONE FETCH.** Model weights are downloaded with a body-less GET for a URL fixed at
//!    compile time ([`models::HttpFetcher`]). No audio has a path into that request.
//! 5. **THE WIRE TEST.** `http::tests::recorded_audio_never_reaches_a_hosted_backend` points
//!    the active model AND its vision helper at a recording server, pushes a recording with a
//!    canary through both the transcription door and the turn door, and fails if one byte of
//!    it arrives.
//!
//! # Custody
//!
//! The upload and every working copy derived from it (the decoded 16 kHz file) live in one
//! 0700 directory per run, removed by `Drop` when the run ends — on success, on every
//! failure, on cancel, and on a panic's unwind. A bridge killed mid-run leaves the directory
//! behind, and boot deletes everything under the intake root: jobs are in memory, so anything
//! there is by definition abandoned. The conditioned signal is never written at all. The
//! bridge keeps the TRANSCRIPT (in memory, for an hour, so the app can collect it); it never
//! keeps the audio.
//!
//! # After the transcript
//!
//! Nothing here touches a turn. The app puts the transcript in the composer and the user
//! sends it like any message, to whatever model the bridge is configured to use. The one
//! thing this adds downstream is the DISAGREEMENT LIST ([`reconcile`]): where two local
//! engines read the same stretch differently, both readings are returned, so the model that
//! later reads the transcript can resolve a date or a name the way a person would — and say
//! when it cannot.

pub mod condition;
pub mod decode;
pub mod engine;
pub mod http;
pub mod intake;
pub mod models;
pub mod reconcile;
pub mod service;
pub mod wav;

pub use http::{jesse_speech, jesse_transcribe, jesse_transcription, jesse_transcription_cancel};
pub use models::{CheckReport, SpeechTier};
pub use service::{SpeechConfig, SpeechService};
