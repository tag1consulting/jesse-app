//! Decoding a recording into what an engine reads: 16 kHz mono samples.
//!
//! AAC in an MP4 box is what Voice Memos records, and it is not a codec to hand-roll. So the
//! decode shells out to `afconvert`, which ships with macOS, runs in the bridge process's own
//! account with no network, and writes its output INTO THE RUN'S CUSTODY DIRECTORY — the
//! decoded working copy is deleted with the upload. This is the same trade the attachment
//! path makes with `sips` for HEIC: a system tool that is already on every Mac, rather than a
//! native codec library on a path that runs over uploaded bytes.
//!
//! A WAV that is already 16 kHz is read directly, with no tool at all — which is also what
//! lets every test in this module tree run on a host that has no `afconvert`.

use super::wav::{self, ENGINE_SAMPLE_RATE};
use std::path::{Path, PathBuf};

/// Why a recording produced no samples.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    /// The container is audio by its header, and the decoder could not read it: truncated,
    /// corrupt, or a codec inside the box the system does not decode.
    Unreadable(String),
    /// This host has no decoder for this container.
    NoDecoder(String),
}

/// Turn a file in custody into engine samples.
pub trait AudioDecoder: Send + Sync {
    /// `work_dir` is the run's custody directory; any intermediate file goes there, so the
    /// custody rule deletes it.
    fn decode(&self, input: &Path, work_dir: &Path) -> Result<Vec<f32>, DecodeError>;
}

/// The system decoder's fixed path. Absolute, so nothing on `PATH` can stand in for it.
pub const AFCONVERT: &str = "/usr/bin/afconvert";

/// The decoded working copy's name inside the custody directory.
pub const DECODED_NAME: &str = "decoded-16k.wav";

/// `afconvert`, plus the direct read for a WAV that needs no conversion.
pub struct SystemDecoder {
    tool: PathBuf,
}

impl Default for SystemDecoder {
    fn default() -> Self {
        SystemDecoder {
            tool: PathBuf::from(AFCONVERT),
        }
    }
}

impl SystemDecoder {
    /// A decoder whose tool is somewhere else — a test pointing it at nothing, to prove the
    /// direct path needs no tool.
    pub fn with_tool(tool: PathBuf) -> Self {
        SystemDecoder { tool }
    }
}

impl AudioDecoder for SystemDecoder {
    fn decode(&self, input: &Path, work_dir: &Path) -> Result<Vec<f32>, DecodeError> {
        if input.extension().and_then(|e| e.to_str()) == Some("wav") {
            if let Ok(pcm) = wav::read_wav(input) {
                if pcm.sample_rate == ENGINE_SAMPLE_RATE {
                    return non_empty(pcm.samples);
                }
            }
        }
        if !self.tool.is_file() {
            return Err(DecodeError::NoDecoder(format!(
                "{} is not on this machine, so only a 16 kHz WAV can be read here",
                self.tool.display()
            )));
        }
        let out = work_dir.join(DECODED_NAME);
        let run = std::process::Command::new(&self.tool)
            .args(["-f", "WAVE", "-d", "LEI16@16000", "-c", "1"])
            .arg(input)
            .arg(&out)
            .output()
            .map_err(|e| {
                DecodeError::NoDecoder(format!("could not run {}: {e}", self.tool.display()))
            })?;
        if !run.status.success() {
            return Err(DecodeError::Unreadable(format!(
                "the system decoder could not read it ({})",
                String::from_utf8_lossy(&run.stderr).trim()
            )));
        }
        let pcm = wav::read_wav(&out).map_err(DecodeError::Unreadable)?;
        if pcm.sample_rate != ENGINE_SAMPLE_RATE {
            return Err(DecodeError::Unreadable(format!(
                "the decoder produced {} Hz rather than {ENGINE_SAMPLE_RATE}",
                pcm.sample_rate
            )));
        }
        non_empty(pcm.samples)
    }
}

fn non_empty(samples: Vec<f32>) -> Result<Vec<f32>, DecodeError> {
    if samples.is_empty() {
        Err(DecodeError::Unreadable(
            "the file holds no audio".to_string(),
        ))
    } else {
        Ok(samples)
    }
}

#[cfg(test)]
pub mod fakes {
    use super::*;

    /// A decoder that answers what it is told, for the pipeline tests.
    pub struct ScriptedDecoder(pub Result<Vec<f32>, DecodeError>);

    impl AudioDecoder for ScriptedDecoder {
        fn decode(&self, _input: &Path, _work_dir: &Path) -> Result<Vec<f32>, DecodeError> {
            self.0.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-decode-{}", crate::random_hex()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_16k_wav_needs_no_tool() {
        let dir = scratch();
        let input = dir.join("upload.wav");
        std::fs::write(&input, wav::encode_wav16(&[0.25; 1600], 16_000)).unwrap();
        let d = SystemDecoder::with_tool(dir.join("no-such-tool"));
        let samples = d.decode(&input, &dir).expect("direct read");
        assert_eq!(samples.len(), 1600);
        assert!(
            !dir.join(DECODED_NAME).exists(),
            "no working copy for a direct read"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn anything_else_without_the_tool_is_a_named_refusal() {
        let dir = scratch();
        let input = dir.join("upload.wav");
        std::fs::write(&input, wav::encode_wav16(&[0.25; 441], 44_100)).unwrap();
        let d = SystemDecoder::with_tool(dir.join("no-such-tool"));
        match d.decode(&input, &dir) {
            Err(DecodeError::NoDecoder(m)) => assert!(m.contains("16 kHz"), "{m}"),
            other => panic!("expected NoDecoder, got {other:?}"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_recording_is_unreadable() {
        let dir = scratch();
        let input = dir.join("upload.wav");
        std::fs::write(&input, wav::encode_wav16(&[], 16_000)).unwrap();
        let d = SystemDecoder::with_tool(dir.join("no-such-tool"));
        assert_eq!(
            d.decode(&input, &dir),
            Err(DecodeError::Unreadable(
                "the file holds no audio".to_string()
            ))
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The real conversion, where the real tool exists: a 44.1 kHz stereo file comes back as
    /// 16 kHz mono, and the working copy lands in the directory it was given.
    #[test]
    #[cfg(target_os = "macos")]
    fn afconvert_resamples_and_downmixes_into_the_work_dir() {
        let dir = scratch();
        let input = dir.join("upload.wav");
        let mut stereo = wav::encode_wav16(&[0.1; 44_100 * 2], 44_100);
        // Reinterpret the mono data as one second of stereo.
        stereo[22] = 2;
        stereo[28..32].copy_from_slice(&(44_100u32 * 4).to_le_bytes());
        stereo[32] = 4;
        std::fs::write(&input, stereo).unwrap();
        let samples = SystemDecoder::default()
            .decode(&input, &dir)
            .expect("afconvert reads a WAV");
        assert!(
            (15_800..=16_200).contains(&samples.len()),
            "{}",
            samples.len()
        );
        assert!(dir.join(DECODED_NAME).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn afconvert_refusing_garbage_is_unreadable_not_a_crash() {
        let dir = scratch();
        let input = dir.join("upload.m4a");
        std::fs::write(
            &input,
            b"\x00\x00\x00\x1cftypM4A garbage that is not a movie",
        )
        .unwrap();
        assert!(matches!(
            SystemDecoder::default().decode(&input, &dir),
            Err(DecodeError::Unreadable(_))
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
