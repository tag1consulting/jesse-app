//! Conditioning: the light pre-pass that makes far-field audio legible to a speech model.
//!
//! # What it does, in the order it does it
//!
//! 1. a HIGH-PASS at 150 Hz — rumble, HVAC, handling noise and the bottom of a music bed
//!    carry no speech and pull the model's attention;
//! 2. a LOW-PASS at 3.8 kHz — holds the speech band and drops the hiss above it;
//! 3. a BROADBAND DENOISE — spectral gating against a per-bin noise floor estimated from
//!    the quietest frames of the recording itself;
//! 4. LOUDNESS NORMALIZATION — the speech-bearing frames are brought to a fixed level, so
//!    a far voice is not decoded as near-silence.
//!
//! In field testing that chain turned a mostly unusable reading of a reverberant parish
//! hall recording into a readable one on the same model. It is also exactly the chain
//! that can slightly HURT a clean close-mic recording (the band limit and the gate both
//! remove something), which is why it is not unconditional: [`decide`] runs it only when
//! the cheap features in [`SignalFeatures`] say the recording looks like a room mic, and
//! the caller can always force it on or off.
//!
//! # Why hand-rolled
//!
//! Two biquads, a 512-point FFT and an overlap-add are a few hundred lines of arithmetic,
//! auditable in one sitting, with no native code and no new crate on a path that runs over
//! uploaded bytes. The alternative the brief allowed — shelling out to an audio tool —
//! would mean ffmpeg, which is not on a stock Mac. The one system tool this pipeline does
//! use is `afconvert`, for DECODING, because AAC is not something to hand-roll.
//!
//! Self-contained (std only), so the probe that measured it includes this exact file.

/// Cheap signal features, measured once over the whole recording in 20 ms frames.
///
/// All three are frame-RMS percentiles in dBFS, floored at [`SILENCE_DBFS`] so a stretch
/// of digital zero (a synthesized recording, a muted input) reads as very quiet rather
/// than as minus infinity.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SignalFeatures {
    /// Level of the loud, speech-bearing frames: the 90th percentile.
    pub speech_dbfs: f32,
    /// The noise floor: the 10th percentile.
    pub floor_dbfs: f32,
    /// The typical frame: the median. Between the floor and the speech level on a room
    /// recording; pinned near the speech level on a close mic with pauses.
    pub median_dbfs: f32,
}

impl SignalFeatures {
    /// Speech level over noise floor, in dB — a crude SNR.
    pub fn snr_db(&self) -> f32 {
        self.speech_dbfs - self.floor_dbfs
    }
}

/// What a frame of digital zero measures as.
pub const SILENCE_DBFS: f32 = -100.0;

/// Below this the speech itself is quiet: a far talker, or a phone left on a table.
pub const QUIET_SPEECH_DBFS: f32 = -30.0;

/// Below this the noise floor is close enough to the speech to matter: room tone, a music
/// bed, HVAC, a reverberant tail filling every pause.
pub const NOISY_SNR_DB: f32 = 30.0;

const FRAME: usize = 320; // 20 ms at 16 kHz

/// Measure [`SignalFeatures`]. Empty or all-silent input yields the silence floor
/// everywhere, which [`decide`] reads as "quiet" and conditions — harmless, since there is
/// nothing to hurt.
pub fn measure(samples: &[f32]) -> SignalFeatures {
    let mut levels: Vec<f32> = samples
        .chunks(FRAME)
        .filter(|f| f.len() == FRAME)
        .map(frame_dbfs)
        .collect();
    if levels.is_empty() {
        return SignalFeatures {
            speech_dbfs: SILENCE_DBFS,
            floor_dbfs: SILENCE_DBFS,
            median_dbfs: SILENCE_DBFS,
        };
    }
    levels.sort_by(|a, b| a.total_cmp(b));
    SignalFeatures {
        speech_dbfs: percentile(&levels, 0.90),
        floor_dbfs: percentile(&levels, 0.10),
        median_dbfs: percentile(&levels, 0.50),
    }
}

fn frame_dbfs(f: &[f32]) -> f32 {
    let power = f.iter().map(|s| s * s).sum::<f32>() / f.len().max(1) as f32;
    (10.0 * power.max(1e-20).log10()).max(SILENCE_DBFS)
}

fn percentile(sorted: &[f32], p: f32) -> f32 {
    let idx = ((sorted.len() - 1) as f32 * p).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

/// What the caller asked for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConditioningRequest {
    /// Decide from the recording (the default).
    Auto,
    /// Always condition.
    On,
    /// Never condition.
    Off,
}

impl ConditioningRequest {
    /// Parse the request's `conditioning` value. Absent is `Auto`; anything unrecognized
    /// is an error rather than a silent `Auto`, because a typo'd override that quietly did
    /// nothing is precisely an override nobody can trust.
    pub fn parse(raw: Option<&str>) -> Result<Self, String> {
        match raw.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
            None | Some("") | Some("auto") => Ok(ConditioningRequest::Auto),
            Some("on") | Some("true") | Some("1") => Ok(ConditioningRequest::On),
            Some("off") | Some("false") | Some("0") => Ok(ConditioningRequest::Off),
            Some(other) => Err(format!(
                "conditioning must be \"auto\", \"on\" or \"off\", got {other:?}"
            )),
        }
    }
}

/// The decision, with the reason it can be reported under.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConditioningDecision {
    Apply(ConditioningReason),
    Skip(ConditioningReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConditioningReason {
    /// The caller forced it.
    Requested,
    /// The speech is quiet ([`QUIET_SPEECH_DBFS`]).
    QuietSpeech,
    /// The noise floor sits close under the speech ([`NOISY_SNR_DB`]).
    NoisyRoom,
    /// Loud speech over a low floor: a close mic, which conditioning can only hurt.
    CleanRecording,
}

impl ConditioningReason {
    pub fn label(self) -> &'static str {
        match self {
            ConditioningReason::Requested => "requested",
            ConditioningReason::QuietSpeech => "quiet speech",
            ConditioningReason::NoisyRoom => "noisy room",
            ConditioningReason::CleanRecording => "clean recording",
        }
    }
}

impl ConditioningDecision {
    pub fn applies(self) -> bool {
        matches!(self, ConditioningDecision::Apply(_))
    }

    pub fn reason(self) -> ConditioningReason {
        match self {
            ConditioningDecision::Apply(r) | ConditioningDecision::Skip(r) => r,
        }
    }
}

/// THE TRIGGER, pure: whether to condition this recording.
///
/// Quiet speech or a floor close under it — either is what a room mic looks like, and
/// either is what conditioning was measured to help. A loud voice over a low floor is a
/// close mic, where the band limit and the gate only remove things.
pub fn decide(request: ConditioningRequest, f: &SignalFeatures) -> ConditioningDecision {
    match request {
        ConditioningRequest::On => ConditioningDecision::Apply(ConditioningReason::Requested),
        ConditioningRequest::Off => ConditioningDecision::Skip(ConditioningReason::Requested),
        ConditioningRequest::Auto => {
            if f.speech_dbfs < QUIET_SPEECH_DBFS {
                ConditioningDecision::Apply(ConditioningReason::QuietSpeech)
            } else if f.snr_db() < NOISY_SNR_DB {
                ConditioningDecision::Apply(ConditioningReason::NoisyRoom)
            } else {
                ConditioningDecision::Skip(ConditioningReason::CleanRecording)
            }
        }
    }
}

// ---- The chain ------------------------------------------------------------------

/// Where the band starts: everything below is rumble.
pub const HIGH_PASS_HZ: f32 = 150.0;
/// Where the band stops: the top of the speech band that carries intelligibility.
pub const LOW_PASS_HZ: f32 = 3_800.0;
/// The level speech frames are normalized to.
pub const TARGET_SPEECH_DBFS: f32 = -20.0;
/// The most normalization will add. A recording quieter than this is mostly noise and
/// amplifying it further only amplifies the noise.
pub const MAX_GAIN_DB: f32 = 30.0;

/// Run the whole chain over 16 kHz mono samples, cooperatively cancellable: `cancelled`
/// is polled between stages and inside the long denoise loop, and a `None` return means
/// it was asked to stop.
pub fn condition(
    samples: &[f32],
    sample_rate: u32,
    cancelled: &dyn Fn() -> bool,
) -> Option<Vec<f32>> {
    let fs = sample_rate as f32;
    let mut y = samples.to_vec();
    Biquad::high_pass(HIGH_PASS_HZ, fs).run(&mut y);
    if cancelled() {
        return None;
    }
    Biquad::low_pass(LOW_PASS_HZ, fs).run(&mut y);
    if cancelled() {
        return None;
    }
    let mut y = denoise(&y, cancelled)?;
    normalize(&mut y);
    Some(y)
}

/// A second-order section (RBJ cookbook), run in transposed direct form II.
#[derive(Debug, Clone, Copy)]
pub struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}

impl Biquad {
    const Q: f32 = std::f32::consts::FRAC_1_SQRT_2; // Butterworth

    pub fn high_pass(fc: f32, fs: f32) -> Biquad {
        let (cos, alpha) = Self::prewarp(fc, fs);
        let a0 = 1.0 + alpha;
        Biquad {
            b0: (1.0 + cos) / 2.0 / a0,
            b1: -(1.0 + cos) / a0,
            b2: (1.0 + cos) / 2.0 / a0,
            a1: -2.0 * cos / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    pub fn low_pass(fc: f32, fs: f32) -> Biquad {
        let (cos, alpha) = Self::prewarp(fc, fs);
        let a0 = 1.0 + alpha;
        Biquad {
            b0: (1.0 - cos) / 2.0 / a0,
            b1: (1.0 - cos) / a0,
            b2: (1.0 - cos) / 2.0 / a0,
            a1: -2.0 * cos / a0,
            a2: (1.0 - alpha) / a0,
        }
    }

    fn prewarp(fc: f32, fs: f32) -> (f32, f32) {
        let w0 = 2.0 * std::f32::consts::PI * fc / fs;
        (w0.cos(), w0.sin() / (2.0 * Self::Q))
    }

    pub fn run(&self, x: &mut [f32]) {
        let (mut z1, mut z2) = (0.0f32, 0.0f32);
        for s in x.iter_mut() {
            let input = *s;
            let out = self.b0 * input + z1;
            z1 = self.b1 * input - self.a1 * out + z2;
            z2 = self.b2 * input - self.a2 * out;
            *s = out;
        }
    }
}

const N: usize = 512; // 32 ms at 16 kHz
const HOP: usize = N / 2;
const BINS: usize = N / 2 + 1;
/// How hard the estimated noise is subtracted (over-subtraction factor).
const OVER_SUBTRACT: f32 = 1.6;
/// The quietest a bin is ever gated to (-18 dB). Gating to zero is what produces the
/// "musical noise" warble, and a model hears that as phonemes.
const GAIN_FLOOR: f32 = 0.125;
/// Frames sampled for the noise profile, spread evenly across the recording, so an hour of
/// audio costs a bounded estimate rather than an hour of magnitudes held in memory.
const PROFILE_FRAMES: usize = 4_000;
/// The per-bin percentile taken as the noise floor.
const NOISE_PERCENTILE: f32 = 0.15;

/// Spectral gating with a per-bin noise floor taken from the recording's own quietest
/// frames. sqrt-Hann analysis and synthesis windows at 50% overlap sum to exactly one, so
/// a bin left untouched reconstructs the input.
pub fn denoise(x: &[f32], cancelled: &dyn Fn() -> bool) -> Option<Vec<f32>> {
    if x.len() < N {
        return Some(x.to_vec());
    }
    let fft = Fft::new(N);
    let window: Vec<f32> = (0..N)
        .map(|n| (0.5 - 0.5 * (2.0 * std::f32::consts::PI * n as f32 / N as f32).cos()).sqrt())
        .collect();
    // Pad by one frame at each end so the first and last samples get full overlap.
    let mut padded = vec![0.0f32; x.len() + 2 * N];
    padded[N..N + x.len()].copy_from_slice(x);
    let frames = (padded.len() - N) / HOP + 1;

    let mut re = vec![0.0f32; N];
    let mut im = vec![0.0f32; N];
    let spectrum = |start: usize, re: &mut Vec<f32>, im: &mut Vec<f32>| {
        for n in 0..N {
            re[n] = padded[start + n] * window[n];
            im[n] = 0.0;
        }
        fft.run(re, im, false);
    };

    // The noise profile.
    let step = (frames / PROFILE_FRAMES).max(1);
    let mut mags: Vec<Vec<f32>> = vec![Vec::new(); BINS];
    for f in (0..frames).step_by(step) {
        spectrum(f * HOP, &mut re, &mut im);
        for (k, bin) in mags.iter_mut().enumerate() {
            bin.push((re[k] * re[k] + im[k] * im[k]).sqrt());
        }
    }
    let noise: Vec<f32> = mags
        .iter_mut()
        .map(|bin| {
            bin.sort_by(|a, b| a.total_cmp(b));
            percentile(bin, NOISE_PERCENTILE)
        })
        .collect();

    // The gate, frame by frame, with overlap-add.
    let mut out = vec![0.0f32; padded.len()];
    let mut prev_gain = vec![1.0f32; BINS];
    for f in 0..frames {
        if f % 2_048 == 0 && cancelled() {
            return None;
        }
        let start = f * HOP;
        spectrum(start, &mut re, &mut im);
        for k in 0..BINS {
            let mag = (re[k] * re[k] + im[k] * im[k]).sqrt();
            let raw = if mag > 0.0 {
                (1.0 - OVER_SUBTRACT * noise[k] / mag).max(GAIN_FLOOR)
            } else {
                GAIN_FLOOR
            };
            // Fast attack, slower release: a gain may rise at once (speech onset) but
            // falls at most by half per frame, which is what keeps the gate from chattering.
            let g = raw.max(prev_gain[k] * 0.5);
            prev_gain[k] = g;
            re[k] *= g;
            im[k] *= g;
            // Keep the spectrum Hermitian so the inverse is real.
            if k > 0 && k < N / 2 {
                re[N - k] = re[k];
                im[N - k] = -im[k];
            }
        }
        fft.run(&mut re, &mut im, true);
        for n in 0..N {
            out[start + n] += re[n] * window[n];
        }
    }
    Some(out[N..N + x.len()].to_vec())
}

/// Bring the speech-bearing frames to [`TARGET_SPEECH_DBFS`], never adding more than
/// [`MAX_GAIN_DB`], with a soft knee above 0.9 so a loud cough is rounded rather than
/// clipped. Returns the gain applied, in dB.
pub fn normalize(x: &mut [f32]) -> f32 {
    let f = measure(x);
    if f.speech_dbfs <= SILENCE_DBFS {
        return 0.0;
    }
    // Speech frames are those within 20 dB of the speech level; their mean power is the
    // level that gets normalized, so pauses do not drag the estimate down.
    let gate = f.speech_dbfs - 20.0;
    let (mut power, mut count) = (0.0f64, 0usize);
    for frame in x.chunks(FRAME).filter(|c| c.len() == FRAME) {
        if frame_dbfs(frame) >= gate {
            power += frame.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>();
            count += FRAME;
        }
    }
    if count == 0 {
        return 0.0;
    }
    let level = 10.0 * ((power / count as f64).max(1e-20)).log10() as f32;
    let gain_db = (TARGET_SPEECH_DBFS - level).min(MAX_GAIN_DB);
    let gain = 10f32.powf(gain_db / 20.0);
    const KNEE: f32 = 0.9;
    for s in x.iter_mut() {
        let v = *s * gain;
        let a = v.abs();
        *s = if a > KNEE {
            v.signum() * (KNEE + (1.0 - KNEE) * ((a - KNEE) / (1.0 - KNEE)).tanh())
        } else {
            v
        };
    }
    gain_db
}

/// An iterative radix-2 complex FFT of one fixed power-of-two size.
struct Fft {
    n: usize,
    cos: Vec<f32>,
    sin: Vec<f32>,
    rev: Vec<usize>,
}

impl Fft {
    fn new(n: usize) -> Fft {
        assert!(n.is_power_of_two());
        let bits = n.trailing_zeros();
        let rev = (0..n)
            .map(|i| i.reverse_bits() >> (usize::BITS - bits))
            .collect();
        let (cos, sin) = (0..n / 2)
            .map(|k| {
                let a = -2.0 * std::f64::consts::PI * k as f64 / n as f64;
                (a.cos() as f32, a.sin() as f32)
            })
            .unzip();
        Fft { n, cos, sin, rev }
    }

    /// In place. The inverse is scaled by `1/n`, so `run(fwd)` then `run(inv)` is identity.
    fn run(&self, re: &mut [f32], im: &mut [f32], inverse: bool) {
        let n = self.n;
        for i in 0..n {
            let j = self.rev[i];
            if i < j {
                re.swap(i, j);
                im.swap(i, j);
            }
        }
        let sign = if inverse { -1.0 } else { 1.0 };
        let mut len = 2;
        while len <= n {
            let stride = n / len;
            for start in (0..n).step_by(len) {
                for k in 0..len / 2 {
                    let (wr, wi) = (self.cos[k * stride], sign * self.sin[k * stride]);
                    let (a, b) = (start + k, start + k + len / 2);
                    let tr = re[b] * wr - im[b] * wi;
                    let ti = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
            }
            len <<= 1;
        }
        if inverse {
            let scale = 1.0 / n as f32;
            for i in 0..n {
                re[i] *= scale;
                im[i] *= scale;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FS: f32 = 16_000.0;

    fn tone(hz: f32, secs: f32, amp: f32) -> Vec<f32> {
        (0..(FS * secs) as usize)
            .map(|n| amp * (2.0 * std::f32::consts::PI * hz * n as f32 / FS).sin())
            .collect()
    }

    fn noise(len: usize, amp: f32, mut seed: u32) -> Vec<f32> {
        (0..len)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                (seed as f32 / u32::MAX as f32 - 0.5) * 2.0 * amp
            })
            .collect()
    }

    fn rms_db(x: &[f32]) -> f32 {
        frame_dbfs(x)
    }

    fn never() -> bool {
        false
    }

    #[test]
    fn the_band_limits_cut_what_they_name_and_pass_speech() {
        let hp = Biquad::high_pass(HIGH_PASS_HZ, FS);
        let lp = Biquad::low_pass(LOW_PASS_HZ, FS);
        let mut hum = tone(50.0, 1.0, 0.5);
        hp.run(&mut hum);
        assert!(
            rms_db(&hum[8_000..]) < rms_db(&tone(50.0, 1.0, 0.5)) - 15.0,
            "50 Hz hum is cut"
        );
        let mut hiss = tone(7_000.0, 1.0, 0.5);
        lp.run(&mut hiss);
        assert!(
            rms_db(&hiss[8_000..]) < rms_db(&tone(7_000.0, 1.0, 0.5)) - 12.0,
            "7 kHz is cut"
        );
        let mut voice = tone(1_000.0, 1.0, 0.5);
        hp.run(&mut voice);
        lp.run(&mut voice);
        assert!(
            (rms_db(&voice[8_000..]) - rms_db(&tone(1_000.0, 1.0, 0.5))).abs() < 1.0,
            "1 kHz passes both"
        );
    }

    #[test]
    fn the_fft_round_trips() {
        let fft = Fft::new(N);
        let x = noise(N, 0.5, 7);
        let (mut re, mut im) = (x.clone(), vec![0.0; N]);
        fft.run(&mut re, &mut im, false);
        fft.run(&mut re, &mut im, true);
        for (a, b) in re.iter().zip(&x) {
            assert!((a - b).abs() < 1e-4);
        }
    }

    /// The gate lowers stationary noise where there is nothing else, and leaves a tone
    /// that stands above that noise essentially where it was.
    #[test]
    fn denoise_lowers_the_floor_and_keeps_what_stands_above_it() {
        let secs = 4.0;
        let len = (FS * secs) as usize;
        let hiss = noise(len, 0.02, 99);
        let mut x = hiss.clone();
        // A tone in the second half only, well above the noise.
        let t = tone(700.0, secs / 2.0, 0.3);
        for (n, s) in t.iter().enumerate() {
            x[len / 2 + n] += s;
        }
        let y = denoise(&x, &never).expect("not cancelled");
        assert_eq!(y.len(), x.len());
        let quiet_before = rms_db(&x[4_000..len / 2 - 4_000]);
        let quiet_after = rms_db(&y[4_000..len / 2 - 4_000]);
        assert!(
            quiet_after < quiet_before - 5.0,
            "noise-only stretch: {quiet_before:.1} -> {quiet_after:.1} dB"
        );
        let loud_before = rms_db(&x[len / 2 + 4_000..len - 4_000]);
        let loud_after = rms_db(&y[len / 2 + 4_000..len - 4_000]);
        assert!(
            (loud_before - loud_after).abs() < 1.5,
            "tone stretch: {loud_before:.1} -> {loud_after:.1} dB"
        );
    }

    #[test]
    fn denoise_is_cancellable() {
        let x = noise((FS * 200.0) as usize, 0.1, 3);
        assert!(denoise(&x, &|| true).is_none());
    }

    #[test]
    fn normalize_brings_quiet_speech_to_the_target_and_caps_the_gain() {
        let mut quiet = tone(440.0, 2.0, 0.01);
        let gain = normalize(&mut quiet);
        assert!(gain > 20.0, "added {gain} dB");
        assert!((rms_db(&quiet[1_000..]) - TARGET_SPEECH_DBFS).abs() < 1.0);

        let mut whisper = tone(440.0, 2.0, 0.000_1);
        assert_eq!(normalize(&mut whisper), MAX_GAIN_DB, "gain is capped");

        let mut silence = vec![0.0f32; 16_000];
        assert_eq!(normalize(&mut silence), 0.0, "nothing to normalize");
        assert!(silence.iter().all(|s| *s == 0.0));
    }

    #[test]
    fn normalize_never_clips() {
        let mut loud = tone(440.0, 1.0, 0.99);
        loud.extend(tone(440.0, 1.0, 0.05));
        normalize(&mut loud);
        assert!(loud.iter().all(|s| s.abs() <= 1.0));
    }

    #[test]
    fn features_separate_a_close_mic_from_a_room() {
        // Close mic: loud speech with real pauses of near-silence.
        let mut close = tone(300.0, 2.0, 0.3);
        close.extend(noise(32_000, 0.000_3, 5));
        close.extend(tone(300.0, 2.0, 0.3));
        let f = measure(&close);
        assert!(f.speech_dbfs > QUIET_SPEECH_DBFS, "{f:?}");
        assert!(f.snr_db() > NOISY_SNR_DB, "{f:?}");
        assert_eq!(
            decide(ConditioningRequest::Auto, &f),
            ConditioningDecision::Skip(ConditioningReason::CleanRecording)
        );

        // Room: the same speech far away, over a floor that never drops out.
        let mut room = tone(300.0, 2.0, 0.02);
        room.extend(noise(32_000, 0.004, 5));
        room.extend(tone(300.0, 2.0, 0.02));
        for (s, n) in room.iter_mut().zip(noise(96_000, 0.004, 9)) {
            *s += n;
        }
        let f = measure(&room);
        assert_eq!(
            decide(ConditioningRequest::Auto, &f),
            ConditioningDecision::Apply(ConditioningReason::QuietSpeech)
        );
    }

    /// THE TRIGGER, as a table over features rather than audio: every branch, and both
    /// overrides beating every feature.
    #[test]
    fn the_trigger_is_a_pure_decision_over_three_numbers() {
        let feats = |speech: f32, floor: f32| SignalFeatures {
            speech_dbfs: speech,
            floor_dbfs: floor,
            median_dbfs: (speech + floor) / 2.0,
        };
        use ConditioningDecision::*;
        use ConditioningReason::*;
        let auto = ConditioningRequest::Auto;
        assert_eq!(decide(auto, &feats(-40.0, -90.0)), Apply(QuietSpeech));
        assert_eq!(decide(auto, &feats(-18.0, -40.0)), Apply(NoisyRoom));
        assert_eq!(decide(auto, &feats(-18.0, -70.0)), Skip(CleanRecording));
        // The boundaries belong to the clean side: exactly at a threshold is not below it.
        assert_eq!(
            decide(
                auto,
                &feats(QUIET_SPEECH_DBFS, QUIET_SPEECH_DBFS - NOISY_SNR_DB)
            ),
            Skip(CleanRecording)
        );
        for f in [feats(-40.0, -90.0), feats(-18.0, -70.0)] {
            assert_eq!(decide(ConditioningRequest::On, &f), Apply(Requested));
            assert_eq!(decide(ConditioningRequest::Off, &f), Skip(Requested));
        }
    }

    #[test]
    fn the_request_parses_strictly() {
        assert_eq!(
            ConditioningRequest::parse(None),
            Ok(ConditioningRequest::Auto)
        );
        assert_eq!(
            ConditioningRequest::parse(Some("ON")),
            Ok(ConditioningRequest::On)
        );
        assert_eq!(
            ConditioningRequest::parse(Some("off")),
            Ok(ConditioningRequest::Off)
        );
        assert!(ConditioningRequest::parse(Some("maybe")).is_err());
    }

    #[test]
    fn the_whole_chain_keeps_the_length_and_honours_cancel() {
        let x = noise(48_000, 0.05, 11);
        let y = condition(&x, 16_000, &never).expect("runs");
        assert_eq!(y.len(), x.len());
        assert!(condition(&x, 16_000, &|| true).is_none());
    }
}
