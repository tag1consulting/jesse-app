//! The transcription engine: what an engine is, the one real implementation, and the clean-up
//! that runs over whatever any engine returns.
//!
//! # Why whisper.cpp, through `whisper-rs`
//!
//! Chosen by measurement on the Studio (M3 Ultra, Metal), against the alternative the brief
//! named, `candle`. `whisper-rs` builds whisper.cpp 1.8.3 with the Metal library EMBEDDED in
//! the binary (nothing to find beside it at run time) and ran a 41-second test recording at
//! about 0.055 of real time on `large-v3` and 0.02 on `large-v3-turbo`. More to the point it
//! exposes every knob the failure modes below needed. `candle` ships Whisper's MODEL, not its
//! decoder: the temperature fallback, the no-speech and log-probability gates and the timestamp
//! rules live in its examples, so choosing it meant writing the very decoder whose failures
//! the brief catalogues. The licenses are fine: whisper.cpp is MIT, `whisper-rs` Unlicense,
//! the OpenAI Whisper weights MIT.
//!
//! # The failure modes the configuration answers
//!
//! Each field of [`STUDIO_DECODE`] is there because of something that went wrong on hard audio
//! in field testing, and a test pins all of them:
//!
//! * GREEDY, not wide beam search: beam search collapsed a whole 47-minute file to one repeated
//!   non-speech token where greedy read it.
//! * NO CARRIED CONTEXT: a strong prior from a music intro otherwise poisons later speech.
//! * NON-SPEECH TOKENS SUPPRESSED and the no-speech / log-probability gates on, so silence and
//!   music are skipped rather than written down as a music tag or a subtitle credit.
//! * And, after the engine, [`clean_segments`]: a hallucinated credit is dropped and COUNTED,
//!   and a repetition loop is collapsed and MARKED in the text, so a reader can see where the
//!   model struggled rather than being handed a quietly shortened transcript.

use super::models::CatalogEntry;
use super::reconcile::norm_word;
use std::path::Path;
use std::sync::Arc;

/// One stretch of recognised speech.
#[derive(Debug, Clone, PartialEq)]
pub struct Segment {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
    /// The engine's probability that this stretch held no speech at all.
    pub no_speech: f32,
}

impl Segment {
    pub fn new(start_ms: u64, end_ms: u64, text: &str) -> Segment {
        Segment {
            start_ms,
            end_ms,
            text: text.to_string(),
            no_speech: 0.0,
        }
    }
}

/// Progress, 0.0 to 1.0, called from the engine's own thread.
pub type ProgressFn = Arc<dyn Fn(f64) + Send + Sync>;
/// Whether the run has been asked to stop, polled from the engine's own thread.
pub type CancelFn = Arc<dyn Fn() -> bool + Send + Sync>;

/// Everything one reading needs.
pub struct EngineRun<'a> {
    /// 16 kHz mono.
    pub samples: &'a [f32],
    /// A Whisper language code (`it`), or `None` to let the engine detect it.
    pub language: Option<&'a str>,
    pub progress: ProgressFn,
    pub cancelled: CancelFn,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    Cancelled,
    UnknownLanguage(String),
    Failed(String),
}

/// A transcription engine RUNNING IN THIS PROCESS.
///
/// There is deliberately nothing here about where an engine lives: an engine is a loaded
/// model, and the only way to get one is [`EngineLoader::load`] on a file on this disk.
pub trait SpeechEngine: Send + Sync {
    /// The known-good list's id for the model (`whisper-large-v3`).
    fn id(&self) -> &str;
    /// What the app shows while it runs (`Whisper large-v3`).
    fn label(&self) -> &str;
    fn transcribe(&self, run: EngineRun<'_>) -> Result<Vec<Segment>, EngineError>;
}

/// The only constructor of engines: a model file on this disk, loaded into this process.
pub trait EngineLoader: Send + Sync {
    fn load(&self, entry: &CatalogEntry, path: &Path) -> Result<Arc<dyn SpeechEngine>, String>;
}

/// How an engine is told to decode, as data so a test can hold it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DecodeProfile {
    /// `false` is greedy decoding.
    pub beam_search: bool,
    /// Candidates sampled on a temperature fallback (greedy only).
    pub best_of: i32,
    /// Feed the previous segment's text in as context.
    pub carry_context: bool,
    pub suppress_non_speech_tokens: bool,
    pub no_speech_threshold: f32,
    pub logprob_threshold: f32,
    pub entropy_threshold: f32,
    pub temperature_increment: f32,
}

/// THE STUDIO'S DECODE PROFILE. See the module docs for why each value is what it is.
pub const STUDIO_DECODE: DecodeProfile = DecodeProfile {
    beam_search: false,
    best_of: 5,
    carry_context: false,
    suppress_non_speech_tokens: true,
    no_speech_threshold: 0.6,
    logprob_threshold: -1.0,
    entropy_threshold: 2.4,
    temperature_increment: 0.2,
};

/// Loads whisper.cpp models.
pub struct WhisperLoader {
    pub threads: i32,
}

impl EngineLoader for WhisperLoader {
    fn load(&self, entry: &CatalogEntry, path: &Path) -> Result<Arc<dyn SpeechEngine>, String> {
        Ok(Arc::new(WhisperEngine::load(entry, path, self.threads)?))
    }
}

/// One whisper.cpp model, loaded (on the GPU, on macOS). Each reading makes its own decoder
/// state, so one loaded model serves any number of readings.
pub struct WhisperEngine {
    id: String,
    label: String,
    ctx: whisper_rs::WhisperContext,
    threads: i32,
}

impl WhisperEngine {
    pub fn load(entry: &CatalogEntry, path: &Path, threads: i32) -> Result<Self, String> {
        // whisper.cpp logs every tensor of a model load to stderr, which is the bridge's log.
        // With no log backend compiled in, the hook swallows it; the bridge writes its own
        // one-line summary instead.
        whisper_rs::install_logging_hooks();
        let path_str = path.to_str().ok_or("the model path is not UTF-8")?;
        let params = whisper_rs::WhisperContextParameters {
            use_gpu: cfg!(target_os = "macos"),
            ..Default::default()
        };
        let ctx = whisper_rs::WhisperContext::new_with_params(path_str, params)
            .map_err(|e| format!("whisper.cpp could not load {}: {e}", path.display()))?;
        Ok(WhisperEngine {
            id: entry.id.clone(),
            label: entry.label.clone(),
            ctx,
            threads,
        })
    }
}

impl SpeechEngine for WhisperEngine {
    fn id(&self) -> &str {
        &self.id
    }

    fn label(&self) -> &str {
        &self.label
    }

    fn transcribe(&self, run: EngineRun<'_>) -> Result<Vec<Segment>, EngineError> {
        use whisper_rs::{FullParams, SamplingStrategy};
        let language = run.language.unwrap_or("auto");
        if language != "auto" && whisper_rs::get_lang_id(language).is_none() {
            return Err(EngineError::UnknownLanguage(language.to_string()));
        }
        let mut state = self
            .ctx
            .create_state()
            .map_err(|e| EngineError::Failed(format!("could not start a reading: {e}")))?;
        let p = STUDIO_DECODE;
        let mut params = FullParams::new(if p.beam_search {
            SamplingStrategy::BeamSearch {
                beam_size: 5,
                patience: -1.0,
            }
        } else {
            SamplingStrategy::Greedy { best_of: p.best_of }
        });
        params.set_language(Some(language));
        params.set_no_context(!p.carry_context);
        params.set_suppress_nst(p.suppress_non_speech_tokens);
        params.set_suppress_blank(true);
        params.set_no_speech_thold(p.no_speech_threshold);
        params.set_logprob_thold(p.logprob_threshold);
        params.set_entropy_thold(p.entropy_threshold);
        params.set_temperature(0.0);
        params.set_temperature_inc(p.temperature_increment);
        params.set_n_threads(self.threads);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_print_special(false);
        let progress = run.progress.clone();
        params.set_progress_callback_safe(move |pct: i32| {
            progress(pct.clamp(0, 100) as f64 / 100.0);
        });
        // THE CANCEL POLL, installed through the raw API on purpose. whisper-rs 0.16.0's
        // `set_abort_callback_safe` boxes the closure twice and then installs a trampoline typed
        // for the bare closure, so the first abort poll whisper.cpp makes reads a vtable pointer
        // as a closure and the process segfaults — found by the end-to-end run on the Studio,
        // which no fake engine could have shown. This trampoline is typed for exactly the
        // pointer it is given: a `&CancelFn` on THIS stack frame, which outlives `state.full`
        // because `full` returns before this function does. That is the whole safety argument.
        let cancel_poll: *const CancelFn = &run.cancelled;
        // SAFETY: see above — the pointee lives for the whole of `full`, and the trampoline
        // only reads it.
        unsafe {
            params.set_abort_callback(Some(abort_trampoline));
            params.set_abort_callback_user_data(cancel_poll as *mut std::ffi::c_void);
        }

        let result = state.full(params, run.samples);
        if (run.cancelled)() {
            return Err(EngineError::Cancelled);
        }
        result.map_err(|e| EngineError::Failed(format!("whisper.cpp stopped: {e}")))?;
        Ok(state
            .as_iter()
            .map(|s| Segment {
                // whisper.cpp timestamps are in centiseconds.
                start_ms: s.start_timestamp().max(0) as u64 * 10,
                end_ms: s.end_timestamp().max(0) as u64 * 10,
                text: s
                    .to_str_lossy()
                    .map(|t| t.trim().to_string())
                    .unwrap_or_default(),
                no_speech: s.no_speech_probability(),
            })
            .collect())
    }
}

/// whisper.cpp's abort poll: `user_data` is the `*const CancelFn` installed in
/// [`WhisperEngine::transcribe`], alive for the whole call that polls it.
unsafe extern "C" fn abort_trampoline(user_data: *mut std::ffi::c_void) -> bool {
    if user_data.is_null() {
        return false;
    }
    let cancelled = &*(user_data as *const CancelFn);
    cancelled()
}

// ---- After the engine ---------------------------------------------------------------

/// What [`clean_segments`] did, so the result can say so.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Cleaned {
    pub segments: Vec<Segment>,
    /// Segments dropped as something whisper writes over silence or music.
    pub non_speech_dropped: usize,
    /// Repetition loops collapsed, each one marked in the text.
    pub loops_collapsed: usize,
}

/// The mark left where a loop was collapsed. It is IN the transcript on purpose: a reader
/// deserves to know the engine struggled there, and a model reading the transcript later can
/// weigh that stretch accordingly.
pub fn loop_mark(times: usize) -> String {
    format!("[repeated ×{times}, collapsed]")
}

/// Phrases whisper is known to invent over silence and music — subtitle credits and video
/// sign-offs, from the subtitled video it was trained on. A segment is dropped only when it is
/// SHORT and names one, so a real sentence that happens to contain "subtitles" survives.
const NON_SPEECH_CREDITS: [&str; 16] = [
    "subtitles by",
    "subtitled by",
    "captions by",
    "transcribed by",
    "thanks for watching",
    "thank you for watching",
    "please subscribe",
    "like and subscribe",
    "amara.org",
    "sottotitoli",
    "grazie per la visione",
    "iscriviti al canale",
    "sous-titres",
    "untertitel",
    "subtítulos",
    "legendas pela comunidade",
];

/// Whether a segment is non-speech whisper wrote down anyway.
pub fn is_non_speech(text: &str) -> bool {
    let t = text.trim();
    if t.is_empty() {
        return true;
    }
    // A bracketed tag: [Music], (applause), *laughs*.
    let bracketed = (t.starts_with('[') && t.ends_with(']'))
        || (t.starts_with('(') && t.ends_with(')'))
        || (t.len() > 1 && t.starts_with('*') && t.ends_with('*'));
    if bracketed {
        return true;
    }
    // Nothing but music notes and punctuation.
    if !t.chars().any(char::is_alphanumeric) {
        return true;
    }
    let lower = t.to_lowercase();
    t.split_whitespace().count() <= 12 && NON_SPEECH_CREDITS.iter().any(|c| lower.contains(c))
}

/// How many consecutive identical segments make a loop. Two in a row is speech ("Yes. Yes.").
const SEGMENT_LOOP_MIN: usize = 3;
/// The longest phrase looked for as a loop inside one segment, in words.
const PHRASE_LOOP_MAX_WORDS: usize = 8;

/// Drop non-speech, then collapse loops — across segments, then within each one.
pub fn clean_segments(segments: Vec<Segment>) -> Cleaned {
    let before = segments.len();
    let speech: Vec<Segment> = segments
        .into_iter()
        .filter(|s| !is_non_speech(&s.text))
        .collect();
    let non_speech_dropped = before - speech.len();

    let mut loops_collapsed = 0;
    let mut out: Vec<Segment> = Vec::with_capacity(speech.len());
    let mut i = 0;
    while i < speech.len() {
        let key = normalized(&speech[i].text);
        let mut run = 1;
        while i + run < speech.len() && normalized(&speech[i + run].text) == key {
            run += 1;
        }
        let mut seg = speech[i].clone();
        if run >= SEGMENT_LOOP_MIN {
            seg.text = format!("{} {}", seg.text, loop_mark(run));
            seg.end_ms = speech[i + run - 1].end_ms;
            loops_collapsed += 1;
            i += run;
        } else {
            i += 1;
        }
        let (text, n) = collapse_phrase_loops(&seg.text);
        seg.text = text;
        loops_collapsed += n;
        out.push(seg);
    }
    Cleaned {
        segments: out,
        non_speech_dropped,
        loops_collapsed,
    }
}

fn normalized(text: &str) -> Vec<String> {
    text.split_whitespace()
        .map(norm_word)
        .filter(|w| !w.is_empty())
        .collect()
}

/// Collapse a phrase repeated back to back within one segment: one copy is kept and the
/// mark says how many there were. A single word needs six in a row ("no, no, no, no" is how
/// people talk); a longer phrase needs four.
pub fn collapse_phrase_loops(text: &str) -> (String, usize) {
    let words: Vec<&str> = text.split_whitespace().collect();
    let norms: Vec<String> = words.iter().map(|w| norm_word(w)).collect();
    let mut out: Vec<String> = Vec::with_capacity(words.len());
    let mut collapsed = 0;
    let mut i = 0;
    'scan: while i < words.len() {
        for len in 1..=PHRASE_LOOP_MAX_WORDS {
            if i + len * 2 > words.len() {
                break;
            }
            let phrase = &norms[i..i + len];
            if phrase.iter().all(String::is_empty) {
                continue;
            }
            let mut reps = 1;
            while i + (reps + 1) * len <= words.len()
                && norms[i + reps * len..i + (reps + 1) * len] == *phrase
            {
                reps += 1;
            }
            let needed = if len == 1 { 6 } else { 4 };
            if reps >= needed {
                out.extend(words[i..i + len].iter().map(|w| w.to_string()));
                out.push(loop_mark(reps));
                collapsed += 1;
                i += reps * len;
                continue 'scan;
            }
        }
        out.push(words[i].to_string());
        i += 1;
    }
    (out.join(" "), collapsed)
}

#[cfg(test)]
pub mod fakes {
    use super::*;
    use crate::*;
    use std::collections::HashSet;

    /// An engine that returns a script. It can also refuse, or hold until cancelled, so the
    /// pipeline's cancel path is exercised without a model.
    pub struct ScriptedEngine {
        pub id: String,
        pub label: String,
        pub segments: Vec<Segment>,
        pub fail: Option<EngineError>,
        pub hold_until_cancelled: bool,
        /// How many samples each reading was handed, so a test can see conditioning ran on
        /// the same audio and both readings saw it.
        pub readings: Mutex<Vec<usize>>,
    }

    impl ScriptedEngine {
        pub fn new(id: &str, segments: Vec<Segment>) -> ScriptedEngine {
            ScriptedEngine {
                id: id.to_string(),
                label: format!("Scripted {id}"),
                segments,
                fail: None,
                hold_until_cancelled: false,
                readings: Mutex::new(Vec::new()),
            }
        }
    }

    impl SpeechEngine for ScriptedEngine {
        fn id(&self) -> &str {
            &self.id
        }
        fn label(&self) -> &str {
            &self.label
        }
        fn transcribe(&self, run: EngineRun<'_>) -> Result<Vec<Segment>, EngineError> {
            self.readings.lock_ok().push(run.samples.len());
            (run.progress)(0.5);
            if self.hold_until_cancelled {
                while !(run.cancelled)() {
                    std::thread::sleep(Duration::from_millis(5));
                }
                return Err(EngineError::Cancelled);
            }
            if let Some(e) = &self.fail {
                return Err(e.clone());
            }
            (run.progress)(1.0);
            Ok(self.segments.clone())
        }
    }

    /// Loads scripted engines by catalog id, and records what it was asked to load.
    #[derive(Default)]
    pub struct ScriptedLoader {
        pub engines: Mutex<HashMap<String, Arc<ScriptedEngine>>>,
        pub loads: Mutex<Vec<String>>,
        pub refuse: Mutex<HashSet<String>>,
    }

    impl ScriptedLoader {
        pub fn with(engines: Vec<ScriptedEngine>) -> ScriptedLoader {
            let l = ScriptedLoader::default();
            for e in engines {
                l.engines.lock_ok().insert(e.id.clone(), Arc::new(e));
            }
            l
        }
    }

    impl EngineLoader for ScriptedLoader {
        fn load(&self, entry: &CatalogEntry, path: &Path) -> Result<Arc<dyn SpeechEngine>, String> {
            self.loads.lock_ok().push(entry.id.clone());
            if self.refuse.lock_ok().contains(&entry.id) {
                return Err(format!("{} is not a model", entry.id));
            }
            if !path.is_file() {
                return Err(format!("{} is missing", path.display()));
            }
            let e = self
                .engines
                .lock_ok()
                .get(&entry.id)
                .cloned()
                .unwrap_or_else(|| {
                    Arc::new(ScriptedEngine::new(
                        &entry.id,
                        vec![Segment::new(0, 1_000, &format!("read by {}", entry.id))],
                    ))
                });
            Ok(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// THE REAL ENGINE, where a model file is at hand — never in the default run, because no
    /// test may need a model. On the Studio:
    ///
    /// ```text
    /// JESSE_WHISPER_TEST_MODEL=~/.jesse-bridge/speech-models/ggml-large-v3-turbo.bin \
    ///   cargo test --release real_whisper -- --ignored
    /// ```
    ///
    /// It is the test that would have caught whisper-rs 0.16.0's abort trampoline before a
    /// recording did: it runs a reading with the cancel poll installed, then a reading that is
    /// cancelled from the first poll. `JESSE_WHISPER_TEST_WAV` optionally names a 16 kHz WAV of
    /// real speech, which must come back as text.
    #[test]
    #[ignore]
    fn real_whisper_runs_and_honours_cancel() {
        let Some(model) = std::env::var_os("JESSE_WHISPER_TEST_MODEL") else {
            eprintln!("skipped: set JESSE_WHISPER_TEST_MODEL to a ggml model file");
            return;
        };
        let entry = CatalogEntry {
            id: "under-test".to_string(),
            label: "Model under test".to_string(),
            file: String::new(),
            url: String::new(),
            sha256: String::new(),
            bytes: 0,
            tier: super::super::models::SpeechTier::Fast,
            rank: 0,
        };
        let engine = WhisperEngine::load(&entry, Path::new(&model), 4).expect("the model loads");
        let samples: Vec<f32> = match std::env::var_os("JESSE_WHISPER_TEST_WAV") {
            Some(wav) => {
                super::super::wav::read_wav(Path::new(&wav))
                    .expect("a 16 kHz WAV")
                    .samples
            }
            None => (0..16_000 * 5)
                .map(|n| 0.1 * (2.0 * std::f32::consts::PI * 220.0 * n as f32 / 16_000.0).sin())
                .collect(),
        };
        let polls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = polls.clone();
        let never: CancelFn = Arc::new(move || {
            counted.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            false
        });
        let progress: ProgressFn = Arc::new(|_| {});
        let read = engine
            .transcribe(EngineRun {
                samples: &samples,
                language: Some("en"),
                progress: progress.clone(),
                cancelled: never,
            })
            .expect("a reading with the cancel poll installed runs to the end");
        assert!(
            polls.load(std::sync::atomic::Ordering::Relaxed) > 0,
            "whisper.cpp must actually poll the cancel callback"
        );
        if std::env::var_os("JESSE_WHISPER_TEST_WAV").is_some() {
            assert!(
                read.iter().any(|s| !s.text.trim().is_empty()),
                "real speech comes back as text"
            );
        }
        let always: CancelFn = Arc::new(|| true);
        assert_eq!(
            engine.transcribe(EngineRun {
                samples: &samples,
                language: Some("en"),
                progress,
                cancelled: always,
            }),
            Err(EngineError::Cancelled)
        );
    }

    /// THE PROFILE THAT SURVIVED HARD AUDIO. Changing any of these is a decision with a field
    /// failure behind it (see the module docs), so it has to be made here, in the open.
    #[test]
    fn the_decode_profile_is_the_one_that_survived_hard_audio() {
        let p = STUDIO_DECODE;
        assert!(
            !p.beam_search,
            "beam search collapsed a 47-minute file to one token"
        );
        assert!(
            !p.carry_context,
            "a music intro's prior poisoned the speech after it"
        );
        assert!(p.suppress_non_speech_tokens);
        assert!(p.no_speech_threshold > 0.0 && p.no_speech_threshold < 1.0);
        assert!(p.logprob_threshold < 0.0);
        assert!(
            p.temperature_increment > 0.0,
            "a stuck segment must be able to fall back"
        );
    }

    #[test]
    fn what_whisper_writes_over_silence_is_dropped_and_speech_is_not() {
        for junk in [
            "[Music]",
            "(applause)",
            "*laughs*",
            "♪ ♪ ♪",
            "...",
            "",
            "Sottotitoli creati dalla comunità Amara.org",
            "Subtitles by the Amara.org community",
            "Thanks for watching!",
        ] {
            assert!(is_non_speech(junk), "{junk:?} should be dropped");
        }
        for speech in [
            "Thank you for coming to the parish hall tonight.",
            "The subtitles on the projector were wrong, so read the handout.",
            "Grazie a tutti.",
        ] {
            assert!(!is_non_speech(speech), "{speech:?} is speech");
        }
    }

    #[test]
    fn a_looping_segment_run_is_collapsed_and_marked() {
        let segs = vec![
            Segment::new(0, 1_000, "Good evening."),
            Segment::new(1_000, 2_000, "Thank you."),
            Segment::new(2_000, 3_000, "Thank you."),
            Segment::new(3_000, 4_000, "thank you"),
            Segment::new(4_000, 5_000, "Thank you."),
            Segment::new(5_000, 6_000, "Now, the budget."),
        ];
        let c = clean_segments(segs);
        assert_eq!(c.loops_collapsed, 1);
        assert_eq!(c.segments.len(), 3);
        assert_eq!(c.segments[1].text, format!("Thank you. {}", loop_mark(4)));
        assert_eq!(
            (c.segments[1].start_ms, c.segments[1].end_ms),
            (1_000, 5_000)
        );
    }

    #[test]
    fn two_identical_segments_are_speech_not_a_loop() {
        let c = clean_segments(vec![
            Segment::new(0, 1_000, "Yes."),
            Segment::new(1_000, 2_000, "Yes."),
        ]);
        assert_eq!(c.loops_collapsed, 0);
        assert_eq!(c.segments.len(), 2);
    }

    #[test]
    fn a_phrase_loop_inside_a_segment_keeps_one_copy_and_the_mark() {
        let (text, n) = collapse_phrase_loops(
            "and then we said the pickup is Thursday the pickup is Thursday the pickup is \
             Thursday the pickup is Thursday the pickup is Thursday okay",
        );
        assert_eq!(n, 1);
        assert_eq!(
            text,
            format!(
                "and then we said the pickup is Thursday {} okay",
                loop_mark(5)
            )
        );
        let (kept, n) = collapse_phrase_loops("no, no, no, no, that's not it");
        assert_eq!(n, 0, "four no's is how people talk");
        assert_eq!(kept, "no, no, no, no, that's not it");
    }

    #[test]
    fn cleaning_counts_what_it_dropped() {
        let c = clean_segments(vec![
            Segment::new(0, 8_000, "[Music]"),
            Segment::new(8_000, 9_000, "Buonasera."),
            Segment::new(9_000, 10_000, "Sottotitoli a cura di QTSS"),
        ]);
        assert_eq!(c.non_speech_dropped, 2);
        assert_eq!(c.segments.len(), 1);
    }
}
