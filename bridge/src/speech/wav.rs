//! The one audio format the bridge reads and writes itself: RIFF/WAVE PCM.
//!
//! Everything else a recording arrives as (AAC in an MP4 box, MP3, AIFF, CAF, FLAC) is
//! decoded by the system's own converter into THIS — 16 kHz mono signed 16-bit — and the
//! engine reads the result. So this file only has to be right about one container, and it
//! is hand-rolled for the same reason the attachment base64 codec is: the bridge stays
//! dependency-light, and a two-hundred-line reader is easier to audit than a codec crate
//! sitting on a network-facing path.
//!
//! Self-contained on purpose (std only, no `crate::` prelude), so the measurement probe
//! that picked the default model can include this exact file rather than a copy of it.

use std::path::Path;

/// The rate every engine in this module is fed. Whisper models are trained on 16 kHz mono;
/// resampling happens in the decoder, never here.
pub const ENGINE_SAMPLE_RATE: u32 = 16_000;

/// A decoded WAVE file: mono samples in `-1.0..=1.0` and the rate they were recorded at.
#[derive(Debug, Clone, PartialEq)]
pub struct Pcm {
    pub sample_rate: u32,
    pub samples: Vec<f32>,
}

impl Pcm {
    pub fn duration_secs(&self) -> f64 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.samples.len() as f64 / self.sample_rate as f64
    }
}

/// The `fmt ` facts this reader needs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WavFormat {
    /// 1 = integer PCM, 3 = IEEE float. `WAVE_FORMAT_EXTENSIBLE` (0xFFFE) is resolved to
    /// its sub-format here, because that is what `afconvert` writes for plain PCM.
    pub format: u16,
    pub channels: u16,
    pub sample_rate: u32,
    pub bits: u16,
}

const FORMAT_PCM: u16 = 1;
const FORMAT_FLOAT: u16 = 3;
const FORMAT_EXTENSIBLE: u16 = 0xFFFE;

/// Parse a WAVE file's bytes. Accepts 16/24/32-bit integer PCM and 32-bit float, any
/// channel count (downmixed to mono by averaging), and walks chunks rather than assuming
/// `data` follows `fmt ` — `afconvert` inserts a `FLLR` padding chunk between them.
pub fn parse_wav(bytes: &[u8]) -> Result<Pcm, String> {
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".to_string());
    }
    let mut fmt: Option<WavFormat> = None;
    let mut data: Option<&[u8]> = None;
    let mut i = 12usize;
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let size =
            u32::from_le_bytes([bytes[i + 4], bytes[i + 5], bytes[i + 6], bytes[i + 7]]) as usize;
        let body_start = i + 8;
        // A truncated final chunk is read as far as it goes: a recording cut short by a
        // full disk is still worth transcribing up to where it stops.
        let body_end = body_start.saturating_add(size).min(bytes.len());
        let body = &bytes[body_start..body_end];
        match id {
            b"fmt " => fmt = Some(parse_fmt(body)?),
            b"data" => data = Some(body),
            _ => {}
        }
        // Chunks are word-aligned: an odd-sized chunk carries one pad byte.
        i = body_start.saturating_add(size).saturating_add(size & 1);
    }
    let fmt = fmt.ok_or("WAVE file has no fmt chunk")?;
    let data = data.ok_or("WAVE file has no data chunk")?;
    if fmt.channels == 0 {
        return Err("WAVE file declares zero channels".to_string());
    }
    let bytes_per_sample = match (fmt.format, fmt.bits) {
        (FORMAT_PCM, 16) => 2,
        (FORMAT_PCM, 24) => 3,
        (FORMAT_PCM, 32) => 4,
        (FORMAT_FLOAT, 32) => 4,
        (f, b) => return Err(format!("unsupported WAVE encoding (format {f}, {b} bits)")),
    };
    let frame = bytes_per_sample * fmt.channels as usize;
    let mut samples = Vec::with_capacity(data.len() / frame);
    for f in data.chunks_exact(frame) {
        let mut acc = 0.0f32;
        for c in f.chunks_exact(bytes_per_sample) {
            acc += match (fmt.format, bytes_per_sample) {
                (FORMAT_PCM, 2) => i16::from_le_bytes([c[0], c[1]]) as f32 / 32_768.0,
                (FORMAT_PCM, 3) => {
                    // Sign-extend the 24-bit value through the top of an i32.
                    (i32::from_le_bytes([0, c[0], c[1], c[2]]) >> 8) as f32 / 8_388_608.0
                }
                (FORMAT_PCM, 4) => {
                    i32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f32 / 2_147_483_648.0
                }
                _ => f32::from_le_bytes([c[0], c[1], c[2], c[3]]),
            };
        }
        samples.push((acc / fmt.channels as f32).clamp(-1.0, 1.0));
    }
    Ok(Pcm {
        sample_rate: fmt.sample_rate,
        samples,
    })
}

fn parse_fmt(body: &[u8]) -> Result<WavFormat, String> {
    if body.len() < 16 {
        return Err("WAVE fmt chunk is too short".to_string());
    }
    let mut format = u16::from_le_bytes([body[0], body[1]]);
    let channels = u16::from_le_bytes([body[2], body[3]]);
    let sample_rate = u32::from_le_bytes([body[4], body[5], body[6], body[7]]);
    let bits = u16::from_le_bytes([body[14], body[15]]);
    if format == FORMAT_EXTENSIBLE {
        // cbSize(2) validBits(2) channelMask(4) then the 16-byte sub-format GUID, whose
        // first two bytes are the plain format code.
        if body.len() < 26 {
            return Err("WAVE_FORMAT_EXTENSIBLE fmt chunk is too short".to_string());
        }
        format = u16::from_le_bytes([body[24], body[25]]);
    }
    Ok(WavFormat {
        format,
        channels,
        sample_rate,
        bits,
    })
}

/// Read and parse a WAVE file from disk.
pub fn read_wav(path: &Path) -> Result<Pcm, String> {
    let bytes =
        std::fs::read(path).map_err(|e| format!("could not read {}: {e}", path.display()))?;
    parse_wav(&bytes)
}

/// Encode mono samples as a 16-bit PCM WAVE file. Samples are clamped, never wrapped.
pub fn encode_wav16(samples: &[f32], sample_rate: u32) -> Vec<u8> {
    let data_len = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + data_len);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&FORMAT_PCM.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&(sample_rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_len as u32).to_le_bytes());
    for s in samples {
        let v = (s.clamp(-1.0, 1.0) * 32_767.0).round() as i16;
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_16_bit_mono_file_round_trips() {
        let samples: Vec<f32> = (0..1600).map(|n| ((n as f32) * 0.01).sin() * 0.5).collect();
        let bytes = encode_wav16(&samples, 16_000);
        let pcm = parse_wav(&bytes).expect("our own encoding parses");
        assert_eq!(pcm.sample_rate, 16_000);
        assert_eq!(pcm.samples.len(), samples.len());
        for (a, b) in pcm.samples.iter().zip(&samples) {
            assert!((a - b).abs() < 1.0 / 16_000.0, "{a} vs {b}");
        }
        assert!((pcm.duration_secs() - 0.1).abs() < 1e-9);
    }

    /// `afconvert -d LEI16@16000` writes WAVE_FORMAT_EXTENSIBLE with a `FLLR` chunk
    /// between `fmt ` and `data`. Both have to be walked past, not assumed away — the
    /// first cut of the measurement probe read the padding as audio.
    #[test]
    fn an_extensible_header_and_a_padding_chunk_are_walked_correctly() {
        let mut b = Vec::new();
        b.extend_from_slice(b"RIFF\0\0\0\0WAVE");
        b.extend_from_slice(b"fmt ");
        b.extend_from_slice(&40u32.to_le_bytes());
        b.extend_from_slice(&FORMAT_EXTENSIBLE.to_le_bytes());
        b.extend_from_slice(&1u16.to_le_bytes());
        b.extend_from_slice(&16_000u32.to_le_bytes());
        b.extend_from_slice(&32_000u32.to_le_bytes());
        b.extend_from_slice(&2u16.to_le_bytes());
        b.extend_from_slice(&16u16.to_le_bytes());
        b.extend_from_slice(&22u16.to_le_bytes()); // cbSize
        b.extend_from_slice(&16u16.to_le_bytes()); // valid bits
        b.extend_from_slice(&4u32.to_le_bytes()); // channel mask
        b.extend_from_slice(&FORMAT_PCM.to_le_bytes()); // sub-format GUID, first two bytes
        b.extend_from_slice(&[0u8; 14]);
        b.extend_from_slice(b"FLLR");
        b.extend_from_slice(&3u32.to_le_bytes()); // odd size: one pad byte follows
        b.extend_from_slice(&[0xAA, 0xAA, 0xAA, 0x00]);
        b.extend_from_slice(b"data");
        b.extend_from_slice(&4u32.to_le_bytes());
        b.extend_from_slice(&16_384i16.to_le_bytes());
        b.extend_from_slice(&(-16_384i16).to_le_bytes());
        let pcm = parse_wav(&b).expect("extensible PCM parses");
        assert_eq!(pcm.samples, vec![0.5, -0.5]);
    }

    #[test]
    fn stereo_is_downmixed_by_averaging() {
        let mut b = encode_wav16(&[], 16_000);
        // Patch the header to two channels and append one stereo frame.
        b[22] = 2;
        b.truncate(40);
        b.extend_from_slice(&4u32.to_le_bytes());
        b.extend_from_slice(&16_384i16.to_le_bytes());
        b.extend_from_slice(&0i16.to_le_bytes());
        let pcm = parse_wav(&b).expect("stereo parses");
        assert_eq!(pcm.samples, vec![0.25]);
    }

    #[test]
    fn what_is_not_a_wave_file_is_refused_with_a_reason() {
        assert!(parse_wav(b"").is_err());
        assert!(parse_wav(b"RIFF\0\0\0\0AVI LIST").is_err());
        let no_data = &encode_wav16(&[0.1], 16_000)[..36];
        assert!(parse_wav(no_data).unwrap_err().contains("data"));
    }
}
